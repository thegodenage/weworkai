defmodule WeworkaiWeb.TaskLive do
  @moduledoc """
  A task's own page, where a human iterates with its agents: reviews the plan and its
  diffs, comments on steps and lines, answers decisions, hands the plan to a coder, reads
  the reviewers' findings, marks a reviewed branch done, and asks agents questions about
  the task (docs/workflow.md, "Human loop").
  """
  use WeworkaiWeb, :live_view

  @behaviour WeworkaiWeb.NotificationsHook

  import WeworkaiWeb.TaskComponents
  import WeworkaiWeb.UsageComponents, only: [usage: 1]
  import WeworkaiWeb.ProofOfWorkComponents, only: [proof_of_work: 1]

  alias Weworkai.{Agents, Board, Diff, ErrorText, Scheduling, Workflows}
  alias Weworkai.Workflows.{Engine, Graph}
  alias Weworkai.Agents.Agent.Role
  alias Weworkai.Agents.Usage
  alias Weworkai.Board.ProofOfWork
  alias Weworkai.Board.Task.Activity
  alias Weworkai.Organization.DefaultAgent
  alias Weworkai.Scheduling.Job.Stage
  alias Weworkai.Scheduling.ScheduledJob.State
  alias WeworkaiWeb.{FolderPicker, TaskBudget, TaskDependencies}

  @tabs ~w(plan questions findings ask activity runs)
  @thread_kinds [:question, :reply, :unanswered]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Board.get_task(id) do
      {:ok, task} ->
        if connected?(socket), do: Phoenix.PubSub.subscribe(Weworkai.PubSub, "tasks")

        {:ok,
         socket
         |> assign(
           selected_steps: MapSet.new(),
           line_refs: [],
           comment: "",
           decision_comment: "",
           answers: %{},
           question: "",
           repository_form: nil
         )
         |> load(task)}

      {:error, _} ->
        {:ok, socket |> put_flash(:error, "Task not found.") |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab_chosen? = params["tab"] in @tabs
    tab = if tab_chosen?, do: params["tab"], else: default_tab(socket.assigns.task)
    {:noreply, socket |> assign(tab: tab, tab_chosen?: tab_chosen?) |> stream_history()}
  end

  defp default_tab(%{plan: plan}) when not is_nil(plan), do: "plan"
  defp default_tab(%{open_questions: [_ | _]}), do: "questions"
  defp default_tab(%{findings: [_ | _]}), do: "findings"
  defp default_tab(_task), do: "activity"

  # Actions return the task without its activity, which the header and banner show; its
  # block may have changed with the action.
  defp load(socket, task) do
    previous = socket.assigns[:task]

    task =
      task
      |> Ash.load!(:activity, lazy?: true)
      |> Ash.load!(
        [:current_node, :open_blocker_titles, :blocker_ids, :dependent_ids, :child_ids],
        reuse_values?: false
      )

    running = Workflows.running!(task)
    graph = running.graph
    approval = if awaiting_plan_review?(task), do: Engine.approval(task, graph)
    answerer = Engine.answerer()

    socket
    |> assign(
      task: task,
      page_title: task.title,
      workflow: running.workflow,
      version: running.version,
      upgrade: upgrade(task, running),
      steps: plan_steps(task.plan),
      approval: approval,
      coders: coders(approval),
      default_coder?: default_coder?(approval),
      decisions: decisions(task, graph, approval),
      max_fix_rounds: Engine.fix_round_limit(graph),
      continue_targets: Board.continue_targets(task),
      ready_to_merge?: Engine.ready_to_merge?(task),
      pending_asks: length(Scheduling.active_asks!(task.id)),
      usage: Usage.total(Agents.task_usage!(task.id)),
      answerer: answerer,
      # With no planner at all, asking makes the default one (TaskMessage.Changes.Ask).
      default_answerer?: is_nil(answerer) and DefaultAgent.available?(:planner)
    )
    |> then(&if(previous && previous.plan != task.plan, do: clear_selection(&1), else: &1))
    |> follow_default_tab()
    |> load_diff(socket.assigns[:ready_to_merge?])
    |> stream_history()
  end

  # A task on a block of an older version than its workflow's latest: whether it can move.
  defp upgrade(_task, %{version: version, workflow: %{version: version}}), do: nil
  defp upgrade(task, _running), do: Workflows.upgrade(task)

  # The branch is read from the bridge once per arrival at the gate, not on every update.
  defp load_diff(%{assigns: %{ready_to_merge?: true, task: task}} = socket, previously_ready?)
       when previously_ready? != true do
    assign_async(socket, :diff_files, fn ->
      with {:ok, files} <- ProofOfWork.diff_files(task), do: {:ok, %{diff_files: files}}
    end)
  end

  defp load_diff(socket, _previously_ready?), do: socket

  # Until the user picks a tab, the page shows what matters most now (the plan once it lands).
  defp follow_default_tab(%{assigns: %{tab_chosen?: false, task: task}} = socket),
    do: assign(socket, tab: default_tab(task))

  defp follow_default_tab(socket), do: socket

  # Streamed items only reach the page while their tab is rendered, so a tab switch re-streams.
  defp stream_history(socket) do
    task_id = socket.assigns.task.id
    messages = Board.list_messages!(task_id)
    runs = Scheduling.task_runs!(task_id)

    thread = Enum.filter(messages, &(&1.kind in @thread_kinds))

    socket
    |> assign(
      message_count: length(messages),
      run_count: length(runs),
      question_count: Enum.count(thread, &(&1.kind == :question)),
      proof:
        socket.assigns.ready_to_merge? &&
          ProofOfWork.new(socket.assigns.task, messages, runs, socket.assigns.usage)
    )
    |> stream(:messages, messages, reset: true)
    |> stream(:thread, thread, reset: true)
    |> stream(:runs, runs, reset: true)
  end

  defp plan_steps(nil), do: []

  defp plan_steps(plan) do
    Enum.map(plan.steps, fn step ->
      %{step: step, changes: Enum.map(step.changes, &%{path: &1.path, diff: Diff.parse(&1.diff)})}
    end)
  end

  # Only coders that can run (model and connector set), as employees. A pick is offered
  # (and pins that coder for the task) only when a coder role block has several to choose
  # from; with one, or a block naming its agent, the plan simply goes on.
  defp coders(nil), do: []

  defp coders(block) do
    [query: [filter: [role: :coder]]]
    |> Agents.runnable_agents!()
    |> Enum.map(& &1.employee)
    |> Enum.filter(&(is_nil(block.employee_id) or &1.id == block.employee_id))
    |> Enum.sort_by(& &1.name)
  end

  # A coder role block with no coder at all gets the default one at approval, while a
  # connector is connected.
  defp default_coder?(%{employee_id: nil}), do: DefaultAgent.available?(:coder)
  defp default_coder?(_block), do: false

  # The human block's arrows as buttons; the plan approval has its own control.
  defp decisions(task, graph, approval) do
    Enum.reject(Engine.decisions(task, graph), fn %{edge: edge} ->
      approval && elem(Graph.resolve(graph, edge.to_node_id), 0).id == approval.id
    end)
  end

  defp clear_selection(socket), do: assign(socket, selected_steps: MapSet.new(), line_refs: [])

  ## Events

  @impl true
  def handle_event("toggle_step", %{"id" => step_id}, socket) do
    {:noreply, update(socket, :selected_steps, &toggle_member(&1, step_id))}
  end

  def handle_event("toggle_line", %{"ref" => ref}, socket) do
    refs = socket.assigns.line_refs
    refs = if ref in refs, do: List.delete(refs, ref), else: refs ++ [ref]
    {:noreply, assign(socket, line_refs: refs)}
  end

  def handle_event("clear_selection", _params, socket), do: {:noreply, clear_selection(socket)}

  def handle_event("comment_change", %{"comment" => %{"body" => body}}, socket) do
    {:noreply, assign(socket, comment: body)}
  end

  def handle_event("request_changes", %{"comment" => %{"body" => body}}, socket) do
    %{task: task, selected_steps: steps, line_refs: refs} = socket.assigns

    case String.trim(body) do
      "" ->
        {:noreply, put_flash(socket, :error, "Write what the planner should change.")}

      text ->
        step_ids = Enum.filter(Enum.map(task.plan.steps, & &1.id), &MapSet.member?(steps, &1))

        case Board.comment_on_plan(task, comment_body(text, refs), step_ids) do
          {:ok, task} ->
            {:noreply,
             socket
             |> clear_selection()
             |> assign(comment: "")
             |> load(task)
             |> put_flash(:info, "Sent to the planner. It is revising the plan.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "The plan no longer waits for comments.")}
        end
    end
  end

  def handle_event("answers_change", %{"answers" => answers}, socket) do
    {:noreply, assign(socket, answers: answers)}
  end

  def handle_event("answer", %{"answers" => answers}, socket) do
    case Board.answer_questions(socket.assigns.task, resolve_answers(answers)) do
      {:ok, task} ->
        {:noreply,
         socket
         |> assign(answers: %{})
         |> load(task)
         |> put_flash(:info, "Answers sent. #{agent_name(task.stage)} picks them up.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Answer every question before sending.")}
    end
  end

  def handle_event("approve", params, socket) do
    case Board.approve_plan(socket.assigns.task, params["coder_id"]) do
      {:ok, task} ->
        {:noreply,
         socket
         |> load(task)
         |> put_flash(:info, "Plan approved. #{task.assignee.name} starts coding.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, Weworkai.ErrorText.readable(error))}
    end
  end

  def handle_event("continue", %{"target" => target}, socket) do
    case Board.continue_task(socket.assigns.task, target) do
      {:ok, task} ->
        {:noreply, socket |> load(task) |> put_flash(:info, continued(task))}

      {:error, error} ->
        {:noreply, socket |> reload() |> put_flash(:error, continue_error(error))}
    end
  end

  def handle_event("upgrade_workflow", _params, socket) do
    case Board.upgrade_task_workflow(socket.assigns.task) do
      {:ok, task} ->
        {:noreply,
         socket
         |> load(task)
         |> put_flash(:info, "The task now runs v#{task.workflow_version} of its workflow.")}

      {:error, error} ->
        {:noreply, socket |> reload() |> put_flash(:error, ErrorText.readable(error))}
    end
  end

  def handle_event("decision_comment", %{"comment" => comment}, socket) do
    {:noreply, assign(socket, decision_comment: comment)}
  end

  def handle_event("decide", %{"edge" => edge_id}, socket) do
    case Board.decide_task(socket.assigns.task, edge_id, socket.assigns.decision_comment) do
      {:ok, task} ->
        {:noreply,
         socket
         |> assign(decision_comment: "")
         |> load(task)
         |> put_flash(:info, "Decided. The task moves on.")}

      {:error, error} ->
        {:noreply, socket |> reload() |> put_flash(:error, continue_error(error))}
    end
  end

  def handle_event("edit_repository", _params, socket) do
    form = to_form(Board.form_to_update_task(socket.assigns.task))
    {:noreply, assign(socket, repository_form: form)}
  end

  def handle_event("cancel_repository", _params, socket) do
    {:noreply, assign(socket, repository_form: nil)}
  end

  def handle_event("validate_repository", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.repository_form, params)
    {:noreply, assign(socket, repository_form: form)}
  end

  def handle_event("save_repository", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.repository_form, params: params) do
      {:ok, task} -> {:noreply, socket |> assign(repository_form: nil) |> load(task)}
      {:error, form} -> {:noreply, assign(socket, repository_form: form)}
    end
  end

  def handle_event("mark_done", _params, socket) do
    case Board.move_task(socket.assigns.task, :done) do
      {:ok, task} -> {:noreply, socket |> load(task) |> put_flash(:info, "Marked done.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not mark the task done.")}
    end
  end

  def handle_event("question_change", %{"ask" => %{"body" => body}}, socket) do
    {:noreply, assign(socket, question: body)}
  end

  def handle_event("ask", %{"ask" => %{"body" => body}}, socket) do
    case String.trim(body) do
      "" ->
        {:noreply, put_flash(socket, :error, "Write your question first.")}

      question ->
        case Board.ask_question(socket.assigns.task.id, question) do
          {:ok, _question} -> {:noreply, socket |> assign(question: "") |> reload()}
          {:error, error} -> {:noreply, put_flash(socket, :error, ErrorText.readable(error))}
        end
    end
  end

  defp toggle_member(set, member) do
    if MapSet.member?(set, member), do: MapSet.delete(set, member), else: MapSet.put(set, member)
  end

  defp comment_body(text, []), do: text

  defp comment_body(text, refs) do
    Enum.join([text, "", "Lines:" | Enum.map(refs, &"- `#{&1}`")], "\n")
  end

  # A written answer wins over a picked option.
  defp resolve_answers(answers) do
    Map.new(answers, fn {id, answer} ->
      other = String.trim(answer["other"] || "")
      {id, if(other == "", do: answer["choice"] || "", else: other)}
    end)
  end

  ## Live updates

  @impl true
  def handle_info({:task_updated, %{id: id}}, %{assigns: %{task: %{id: id}}} = socket) do
    {:noreply, reload(socket)}
  end

  def handle_info({:task_deleted, %{id: id}}, %{assigns: %{task: %{id: id}}} = socket) do
    {:noreply, reload(socket)}
  end

  # A blocker closing, a sub-task moving or born: the header and the dependencies follow.
  # The task itself may be unchanged, so the dependencies are told to look again.
  def handle_info({change, other}, socket) when change in [:task_updated, :task_deleted] do
    if related?(socket.assigns.task, other) do
      socket = reload(socket)
      send_update(TaskDependencies, id: "task-dependencies", task: socket.assigns.task)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Messages of a transition commit with it; its notification is a second chance to see them.
  @impl WeworkaiWeb.NotificationsHook
  def handle_notification({:created, %{task_id: id}}, %{assigns: %{task: %{id: id}}} = socket),
    do: reload(socket)

  def handle_notification(_change, socket), do: socket

  defp related?(task, other) do
    Map.get(other, :parent_id) == task.id or
      other.id in [task.parent_id | task.blocker_ids ++ task.dependent_ids ++ task.child_ids]
  end

  # Workflow changes are announced by their notification's toast, so a reload adds no flash.
  defp reload(socket) do
    case Board.get_task(socket.assigns.task.id) do
      {:ok, task} ->
        socket |> clear_stale_info(task) |> load(task)

      {:error, _} ->
        socket
        |> put_flash(:error, "This task was deleted.")
        |> push_navigate(to: ~p"/")
    end
  end

  # An info flash describes the human's last action ("Plan approved…"); once the task moved
  # on, it is out of date and would cover the toolbar.
  defp clear_stale_info(%{assigns: %{task: %{status: status}}} = socket, %{status: status}),
    do: socket

  defp clear_stale_info(socket, _task), do: clear_flash(socket, :info)

  ## View helpers

  defp agent_name(:planning), do: "The planner"
  defp agent_name(:coding), do: "The coder"
  defp agent_name(:code_review), do: "The code reviewer"
  defp agent_name(:qa), do: "The docker reviewer"
  defp agent_name(nil), do: "The agent"

  defp continued(%{status: :done}), do: "Marked done."
  defp continued(task), do: "Continued. #{agent_name(task.stage)} picks it up shortly."

  defp working_note(%{status: :todo}, _max), do: "picks this up shortly."
  defp working_note(%{status: :review, stage: :code_review}, _max), do: "is reading the change."

  defp working_note(%{status: :review, stage: :qa}, _max),
    do: "is building and testing the change."

  defp working_note(%{stage: :coding, review_round: round}, max) when round > 0,
    do: "is fixing the reviewers' findings (fix round #{round} of #{max})."

  defp working_note(_task, _max), do: "is working on it."

  # Which conversation a question continues (Engine.ask_job/3).
  defp asked_context(task, answerer) do
    case Engine.asked_role(task, answerer) do
      :coder -> "a copy of the coder's conversation"
      :planner -> "a copy of the planner's conversation"
      nil -> "the task's description and plan"
    end
  end

  defp awaiting_plan_review?(task) do
    task.stage == :planning and task.status == :await_human_supervision and not is_nil(task.plan)
  end

  defp answerable?(task) do
    task.stage in [:planning, :coding] and task.status == :await_human_supervision and
      task.open_questions != []
  end

  defp line_ref(path, line), do: "#{path}:#{Diff.line_number(line)}"

  defp tab_count("questions", assigns), do: length(assigns.task.open_questions)
  defp tab_count("findings", assigns), do: length(assigns.task.findings)
  defp tab_count("ask", assigns), do: assigns.question_count
  defp tab_count("activity", assigns), do: assigns.message_count
  defp tab_count("runs", assigns), do: assigns.run_count
  defp tab_count("plan", assigns), do: length(assigns.steps)

  defp tab_label("plan"), do: "Plan"
  defp tab_label("questions"), do: "Decisions"
  defp tab_label("findings"), do: "Findings"
  defp tab_label("ask"), do: "Ask"
  defp tab_label("activity"), do: "Activity"
  defp tab_label("runs"), do: "Runs"

  defp tab_icon("plan"), do: "hero-map-micro"
  defp tab_icon("questions"), do: "hero-question-mark-circle-micro"
  defp tab_icon("findings"), do: "hero-bug-ant-micro"
  defp tab_icon("ask"), do: "hero-sparkles-micro"
  defp tab_icon("activity"), do: "hero-chat-bubble-left-right-micro"
  defp tab_icon("runs"), do: "hero-command-line-micro"

  defp step_title(steps, id), do: Enum.find_value(steps, id, &(&1.step.id == id && &1.step.title))

  defp severity_tone(:high), do: "red"
  defp severity_tone(:medium), do: "amber"
  defp severity_tone(:low), do: "slate"

  defp source_label(:reviewer), do: "Code reviewer"
  defp source_label(:qa), do: "Docker reviewer"

  defp run_tone(:started), do: "blue"
  defp run_tone(:completed), do: "green"
  defp run_tone(:failed), do: "red"
  defp run_tone(_pending_or_canceled), do: "slate"

  defp author_label(%{author: :human}), do: "You"
  defp author_label(%{agent_role: nil}), do: "Agent"
  defp author_label(%{agent_role: role}), do: Role.label(role)

  defp kind_label(:comment), do: "commented"
  defp kind_label(:answer), do: "answered"
  defp kind_label(:plan), do: "proposed a plan"
  defp kind_label(:outcome), do: "reported"
  defp kind_label(:findings), do: "reviewed"
  defp kind_label(:system), do: "failed"
  defp kind_label(:restart), do: "continued the task"
  defp kind_label(:question), do: "asked"
  defp kind_label(:reply), do: "answered"
  defp kind_label(:unanswered), do: "could not answer"
  defp kind_label(:decision), do: "decided"

  defp timestamp(datetime), do: Calendar.strftime(datetime, "%b %-d, %H:%M")

  defp checked_choice?(answers, question_id, option),
    do: get_in(answers, [question_id, "choice"]) == option

  defp other_answer(answers, question_id), do: get_in(answers, [question_id, "other"])

  ## Rendering

  @impl true
  def render(assigns) do
    assigns = assign(assigns, tabs: @tabs)

    ~H"""
    <Layouts.app
      flash={@flash}
      active={:kanban}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <.link
        id="back-to-board"
        navigate={~p"/"}
        class="micro-label group mb-3 inline-flex items-center gap-1 transition-colors hover:text-base-content"
      >
        <.icon
          name="hero-arrow-left-micro"
          class="size-3.5 transition-transform group-hover:-translate-x-0.5"
        /> ~/board <span class="opacity-60">/ task/{String.slice(@task.id, 0, 8)}</span>
      </.link>

      <header
        id="task-header"
        class="mb-6 flex flex-wrap items-start justify-between gap-4 border-b border-(--orpheus-border) pb-5"
      >
        <%!-- Keeps room for the title: a long toolbar (decisions, note) wraps below it instead. --%>
        <div class="min-w-[min(100%,26rem)] flex-[1_1_26rem]">
          <div class="mb-2 flex flex-wrap items-center gap-2">
            <.status_badge id="task-status" status={@task.status} />
            <.stage_badge :if={@task.stage} id="task-stage" stage={@task.stage} />
            <.block_badge :if={@task.current_node} id="task-block" block={@task.current_node} />
            <.needs_you :if={@task.status == :await_human_supervision} id="task-needs-you" />
            <.blocked_badge
              :if={@task.open_blocker_titles != []}
              id="task-blocked"
              titles={@task.open_blocker_titles}
            />
            <.agent_activity :if={@task.activity} id="task-working" activity={@task.activity} />
            <.link
              id="task-timeline"
              navigate={~p"/audit/#{@task.id}"}
              class="orpheus-badge tone-slate gap-1 transition-colors hover:text-base-content"
            >
              <.icon name="hero-chart-bar-square-micro" class="size-3" /> Timeline
            </.link>
          </div>
          <h1 id="task-title" class="text-2xl font-semibold tracking-tight [overflow-wrap:anywhere]">
            {@task.title}
          </h1>
          <dl class="mt-3 flex flex-wrap items-center gap-x-5 gap-y-2 text-sm text-(--orpheus-text-secondary)">
            <div :if={@task.assignee} id="task-assignee" class="flex items-center gap-2">
              <dt class="sr-only">Assignee</dt>
              <dd class="flex items-center gap-2">
                <.avatar employee={@task.assignee} />
                {@task.assignee.name}
              </dd>
            </div>
            <div id="task-repository" class="flex items-center gap-1.5">
              <dt><.icon name="hero-folder-micro" class="size-4 text-(--orpheus-text-muted)" /></dt>
              <dd>
                <%= if @repository_form do %>
                  <.form
                    for={@repository_form}
                    id="task-repository-form"
                    phx-change="validate_repository"
                    phx-submit="save_repository"
                    class="flex items-start gap-1.5"
                  >
                    <.live_component
                      module={FolderPicker}
                      id="task-repository-picker"
                      field={@repository_form[:repository]}
                      class="input input-sm w-64 font-mono"
                    />
                    <button id="task-repository-save" class="btn btn-primary btn-sm">Save</button>
                    <button
                      type="button"
                      id="task-repository-cancel"
                      phx-click="cancel_repository"
                      class="btn btn-ghost btn-sm"
                    >
                      Cancel
                    </button>
                  </.form>
                <% else %>
                  <button
                    type="button"
                    id="task-repository-edit"
                    phx-click="edit_repository"
                    title="Change the repository"
                    class="group inline-flex items-center gap-1.5 rounded px-1 -mx-1 transition-colors hover:bg-(--orpheus-hover)"
                  >
                    <code class="text-xs">{@task.repository}</code>
                    <.icon
                      name="hero-pencil-micro"
                      class="size-3.5 text-(--orpheus-text-muted) opacity-0 transition-opacity group-hover:opacity-100"
                    />
                  </button>
                <% end %>
              </dd>
            </div>
            <div id="task-workflow" class="flex items-center gap-1.5">
              <dt>
                <.icon name="hero-arrows-right-left-micro" class="size-4 text-(--orpheus-text-muted)" />
                <span class="sr-only">Workflow</span>
              </dt>
              <dd class="flex flex-wrap items-center gap-1.5">
                <.link
                  navigate={~p"/workflows/#{@workflow.id}"}
                  class="transition-colors hover:text-base-content"
                >
                  {@workflow.name}
                </.link>
                <span
                  id="task-workflow-version"
                  class="font-mono text-xs text-(--orpheus-text-muted)"
                  title="The workflow version this task runs"
                >
                  v{@version}
                </span>
                <%= case @upgrade do %>
                  <% {:ok, latest} -> %>
                    <button
                      id="task-upgrade-workflow"
                      type="button"
                      phx-click="upgrade_workflow"
                      data-confirm={"Move this task to v#{latest}? It stays on its block; what comes next follows v#{latest}."}
                      class="orpheus-badge tone-amber cursor-pointer transition-opacity hover:opacity-80"
                      title={"v#{latest} of the workflow was saved since this task started"}
                    >
                      Move to v{latest}
                    </button>
                  <% {:error, reason} -> %>
                    <span id="task-newer-workflow" class="orpheus-badge tone-slate">
                      v{@workflow.version} available
                    </span>
                    <span id="task-newer-workflow-reason" class="text-xs text-(--orpheus-text-muted)">
                      {reason}
                    </span>
                  <% nil -> %>
                <% end %>
              </dd>
            </div>
            <div :if={@task.worktree_branch} id="task-branch" class="flex items-center gap-1.5">
              <dt><.icon name="hero-share-micro" class="size-4 text-(--orpheus-text-muted)" /></dt>
              <dd><code class="text-xs">{@task.worktree_branch}</code></dd>
            </div>
            <div :if={@usage.runs > 0} id="task-usage" class="flex items-center gap-1.5">
              <dt><.icon name="hero-cpu-chip-micro" class="size-4 text-(--orpheus-text-muted)" /></dt>
              <dd><.usage usage={@usage} /></dd>
            </div>
            <.live_component
              module={TaskBudget}
              id="task-budget"
              task={@task}
              spent={@usage.cost_usd}
            />
            <div :if={@task.plan_approved_at} class="flex items-center gap-1.5">
              <dt><.icon name="hero-check-badge-micro" class="size-4 text-success" /></dt>
              <dd>Plan approved {timestamp(@task.plan_approved_at)}</dd>
            </div>
          </dl>
        </div>

        <div id="task-toolbar" class="flex flex-wrap items-center gap-2">
          <.link
            id="task-edit"
            navigate={~p"/tasks/#{@task.id}/edit"}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-pencil-square-micro" class="size-4" /> Details
          </.link>
          <.continue_control
            id="continue-task"
            targets={@continue_targets}
            working?={Activity.workflow?(@task.activity)}
          />
          <.approve_control
            :if={@approval}
            task={@task}
            coders={@coders}
            default_coder?={@default_coder?}
          />
          <form
            :if={@decisions != []}
            id="decision-form"
            phx-change="decision_comment"
            phx-submit="decision_comment"
            class="flex flex-wrap items-center gap-2"
          >
            <input
              id="decision-comment"
              name="comment"
              value={@decision_comment}
              phx-debounce="blur"
              placeholder="Add a note for the next step (optional)"
              aria-label="Note that goes with your decision"
              title="Goes into the task's messages and the next agent's prompt"
              class="input input-sm w-64"
            />
            <button
              :for={%{edge: edge, target: target} <- @decisions}
              id={"decide-#{edge.id}"}
              type="button"
              phx-click="decide"
              phx-value-edge={edge.id}
              phx-disable-with="Deciding…"
              title={"Goes on to #{target.label}"}
              class="btn btn-outline btn-sm transition-transform active:scale-[0.98]"
            >
              <.icon name="hero-arrow-right-micro" class="size-4" /> {edge.condition}
            </button>
          </form>
          <button
            :if={@ready_to_merge?}
            id="mark-done"
            type="button"
            phx-click="mark_done"
            phx-disable-with="Marking…"
            class="btn btn-primary btn-sm shadow-sm shadow-primary/30 transition-transform active:scale-[0.98]"
            title="You merged the branch; the task is done"
          >
            <.icon name="hero-check-micro" class="size-4" /> Mark done
          </button>
        </div>
      </header>

      <div
        :if={Activity.workflow?(@task.activity)}
        id="agent-working"
        class="mb-6 flex items-center gap-3 border border-primary/40 border-l-2 border-l-primary bg-primary/5 px-4 py-3 text-sm"
      >
        <.spinner class="size-4 text-primary" />
        <span>
          <span class="font-medium">{agent_name(@task.stage)}</span>
          {working_note(@task, @max_fix_rounds)}
          <span class="text-(--orpheus-text-muted)">This page updates when it is done.</span>
        </span>
        <.link
          patch={~p"/tasks/#{@task.id}?tab=runs"}
          class="micro-label ml-auto text-primary transition-colors hover:text-base-content"
        >
          Watch the run &rarr;
        </.link>
      </div>

      <div
        :if={@ready_to_merge?}
        id="ready-to-merge"
        class="mb-6 flex flex-wrap items-center gap-x-3 gap-y-2 border border-success/40 border-l-2 border-l-success bg-success/5 px-4 py-3 text-sm"
      >
        <.icon name="hero-check-badge" class="size-5 shrink-0 text-success" />
        <span class="min-w-0 flex-1">
          <span class="font-medium">Ready to merge.</span>
          <%= if @task.findings == [] do %>
            The reviewers found nothing more on
          <% else %>
            <.link patch={~p"/tasks/#{@task.id}?tab=findings"} class="text-primary hover:underline">
              {length(@task.findings)} {if length(@task.findings) == 1,
                do: "finding is",
                else: "findings are"} still open
            </.link>
            after {@task.review_round} fix rounds on
          <% end %>
          <%!-- Unformatted: whitespace inside the chip would show as a gap before the period. --%>
          <code
            id="ready-to-merge-branch"
            class="border border-(--orpheus-border) bg-base-200 px-1.5 py-0.5 text-xs"
            phx-no-format
          >{@task.worktree_branch}</code>. Merge it, then mark the task done.
        </span>
      </div>

      <.proof_of_work
        :if={@proof}
        proof={@proof}
        diff_files={@diff_files}
        task_id={@task.id}
      />

      <.live_component module={TaskDependencies} id="task-dependencies" task={@task} />

      <nav
        id="task-tabs"
        aria-label="Task sections"
        class="mb-6 flex gap-1 overflow-x-auto border-b border-(--orpheus-border)"
      >
        <.link
          :for={tab <- @tabs}
          id={"tab-#{tab}"}
          patch={~p"/tasks/#{@task.id}?tab=#{tab}"}
          aria-current={@tab == tab && "page"}
          class={[
            "-mb-px flex shrink-0 items-center gap-2 border-b-2 px-3 py-2 text-xs tracking-wider uppercase transition-[color,border-color]",
            if(@tab == tab,
              do: "border-primary font-semibold text-base-content",
              else:
                "border-transparent text-(--orpheus-text-muted) hover:border-(--orpheus-border) hover:text-base-content"
            )
          ]}
        >
          <.icon name={tab_icon(tab)} class="size-4" />
          {tab_label(tab)}
          <span
            :if={tab_count(tab, assigns) > 0}
            class={[
              "border px-1 text-[11px] leading-4 tabular-nums",
              if(tab == "questions" and answerable?(@task),
                do: "tone-amber border-(--tone) bg-(--tone-soft) text-(--tone)",
                else: "border-(--orpheus-border) text-(--orpheus-text-secondary)"
              )
            ]}
          >
            {tab_count(tab, assigns)}
          </span>
        </.link>
      </nav>

      <.plan_tab
        :if={@tab == "plan"}
        task={@task}
        steps={@steps}
        selected_steps={@selected_steps}
        line_refs={@line_refs}
        comment={@comment}
      />
      <.questions_tab :if={@tab == "questions"} task={@task} answers={@answers} />
      <.findings_tab :if={@tab == "findings"} task={@task} max_fix_rounds={@max_fix_rounds} />

      <.ask_tab
        :if={@tab == "ask"}
        task={@task}
        streams={@streams}
        steps={@steps}
        question={@question}
        pending_asks={@pending_asks}
        answerer={@answerer}
        default_answerer?={@default_answerer?}
      />

      <section :if={@tab == "activity"} id="activity-panel" class="max-w-3xl">
        <ol id="messages" phx-update="stream" class="relative space-y-5">
          <li
            id="messages-empty"
            class="hidden py-12 text-center text-sm text-(--orpheus-text-muted) only:block"
          >
            Nothing happened yet. Agents and you write here as the task moves.
          </li>
          <li :for={{id, message} <- @streams.messages} id={id} class="flex gap-3">
            <.message message={message} steps={@steps} />
          </li>
        </ol>
      </section>

      <section :if={@tab == "runs"} id="runs-panel" class="max-w-3xl">
        <ul id="runs" phx-update="stream" class="orpheus-card divide-y divide-(--orpheus-border)">
          <li
            id="runs-empty"
            class="hidden px-4 py-12 text-center text-sm text-(--orpheus-text-muted) only:block"
          >
            No agent has run on this task yet.
          </li>
          <li
            :for={{id, attempt} <- @streams.runs}
            id={id}
            data-stage={attempt.job.stage}
            class="flex items-center gap-3 px-4 py-3 text-sm transition-colors hover:bg-(--orpheus-hover)"
          >
            <.avatar :if={attempt.job.agent.employee} employee={attempt.job.agent.employee} />
            <div class="min-w-0 flex-1">
              <p class="font-medium">
                {if attempt.job.agent.employee, do: attempt.job.agent.employee.name, else: "Agent"}
                <span :if={attempt.job.stage} class="font-normal text-(--orpheus-text-muted)">
                  · {Stage.label(attempt.job.stage)}
                </span>
              </p>
              <p class="text-xs text-(--orpheus-text-muted)">
                {timestamp(attempt.inserted_at)}{if attempt.job.resume, do: " · resumed"}
              </p>
              <p :if={attempt.error} id={"#{id}-error"} class="text-xs text-error">
                {attempt.error}
              </p>
            </div>
            <.usage
              :if={attempt.agent_run.usage}
              id={"#{id}-usage"}
              usage={attempt.agent_run.usage}
              class="text-(--orpheus-text-muted)"
            />
            <span class={["orpheus-badge", "tone-#{run_tone(attempt.state)}"]}>
              {State.label(attempt.state)}
            </span>
            <.link
              navigate={~p"/dashboard/runs/#{attempt.agent_run_id}"}
              class="btn btn-ghost btn-xs"
            >
              Log <.icon name="hero-arrow-up-right-micro" class="size-3.5" />
            </.link>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  attr :task, :map, required: true
  attr :coders, :list, required: true
  attr :default_coder?, :boolean, default: false

  defp approve_control(assigns) do
    ~H"""
    <form
      id="approve-form"
      phx-submit="approve"
      class="flex flex-wrap items-center gap-2"
    >
      <%= case @coders do %>
        <% [] -> %>
          <span
            :if={@default_coder?}
            id="default-coder"
            class="inline-flex items-center gap-1 text-xs text-(--orpheus-text-muted)"
          >
            <.icon name="hero-sparkles-micro" class="size-3.5" />
            A default coder is created on your connector.
          </span>
          <span :if={!@default_coder?} id="no-coder" class="text-xs text-(--orpheus-text-muted)">
            No coder agent yet. <.link navigate={~p"/employees/new"} class="text-primary underline">Add one</.link>.
          </span>
        <% [_coder] -> %>
        <% coders -> %>
          <select
            id="approve-coder"
            name="coder_id"
            aria-label="Coder"
            class="select select-sm w-44"
          >
            <option :for={coder <- coders} value={coder.id}>{coder.name}</option>
          </select>
      <% end %>
      <button
        id="approve-plan"
        type="submit"
        disabled={@coders == [] and not @default_coder?}
        data-confirm={
          @task.open_questions != [] &&
            "#{length(@task.open_questions)} unanswered decisions. Approve the plan anyway?"
        }
        title={@coders == [] and not @default_coder? && "Add an agent with the coder role first"}
        phx-disable-with="Handing over…"
        class="btn btn-primary btn-sm shadow-sm shadow-primary/30 transition-transform active:scale-[0.98]"
      >
        <.icon name="hero-rocket-launch-micro" class="size-4" /> Ready for development
      </button>
    </form>
    """
  end

  ## Plan

  attr :task, :map, required: true
  attr :steps, :list, required: true
  attr :selected_steps, :any, required: true
  attr :line_refs, :list, required: true
  attr :comment, :string, required: true

  defp plan_tab(%{task: %{plan: nil}} = assigns) do
    ~H"""
    <section id="plan-panel" class="orpheus-card px-6 py-16 text-center">
      <.icon name="hero-map" class="mx-auto mb-3 size-8 text-(--orpheus-text-muted)" />
      <p class="font-medium">No plan yet</p>
      <p class="mt-1 text-sm text-(--orpheus-text-muted)">
        Assign a planner agent and move the task to Todo; its plan shows up here.
      </p>
    </section>
    """
  end

  defp plan_tab(assigns) do
    ~H"""
    <section
      id="plan-panel"
      class="grid items-start gap-6 xl:grid-cols-[minmax(0,1fr)_22rem]"
    >
      <div class="min-w-0 space-y-4">
        <div
          :if={answerable?(@task)}
          id="plan-decisions-callout"
          class="tone-amber flex items-center gap-3 border border-(--tone)/40 border-l-2 border-l-(--tone) bg-(--tone-soft) px-4 py-3 text-sm"
        >
          <.icon name="hero-question-mark-circle" class="size-5 shrink-0 text-amber-500" />
          <span class="flex-1">
            The planner needs {length(@task.open_questions)} {if length(@task.open_questions) == 1,
              do: "decision",
              else: "decisions"} before it can finish the plan.
          </span>
          <.link
            patch={~p"/tasks/#{@task.id}?tab=questions"}
            class="btn btn-xs border-amber-400/40 bg-transparent"
          >
            Answer
          </.link>
        </div>

        <article id="plan-summary" class="orpheus-card p-5">
          <h2 class="micro-label mb-2">Summary</h2>
          <.markdown content={@task.plan.summary} class="text-sm" />
        </article>

        <article
          :for={{%{step: step, changes: changes}, index} <- Enum.with_index(@steps, 1)}
          id={"step-#{step.id}"}
          data-selected={MapSet.member?(@selected_steps, step.id)}
          class="orpheus-card overflow-hidden transition-shadow data-selected:shadow-[0_0_0_1px_var(--color-primary)]"
        >
          <header class="flex items-start gap-3 p-4">
            <%!-- daisyUI's checkbox draws no tick in this theme; the box is drawn here instead. --%>
            <label id={"step-#{step.id}-checkbox"} class="mt-0.5 flex cursor-pointer">
              <input
                type="checkbox"
                id={"step-#{step.id}-select"}
                phx-click="toggle_step"
                phx-value-id={step.id}
                checked={MapSet.member?(@selected_steps, step.id)}
                aria-label={"Select step #{step.id} for a comment"}
                class="peer sr-only"
              />
              <span class={[
                "flex size-5 items-center justify-center rounded border transition-colors",
                "peer-focus-visible:outline-2 peer-focus-visible:outline-(--focus-ring)",
                if(MapSet.member?(@selected_steps, step.id),
                  do: "border-primary bg-primary text-primary-content",
                  else: "border-(--orpheus-text-muted)/40 bg-base-100 hover:border-primary"
                )
              ]}>
                <.icon
                  :if={MapSet.member?(@selected_steps, step.id)}
                  name="hero-check-micro"
                  class="size-4"
                />
              </span>
            </label>
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-baseline gap-x-2">
                <span class="micro-label tabular-nums">
                  Step {index |> Integer.to_string() |> String.pad_leading(2, "0")}
                </span>
                <h3 class="font-semibold">{step.title}</h3>
              </div>
              <.markdown
                :if={step.description}
                content={step.description}
                class="mt-1 text-sm text-(--orpheus-text-secondary)"
              />
            </div>
            <span
              :if={changes != []}
              class="shrink-0 text-xs text-(--orpheus-text-muted) tabular-nums"
            >
              {length(changes)} {if length(changes) == 1, do: "file", else: "files"}
            </span>
          </header>

          <.diff_file
            :for={{change, change_index} <- Enum.with_index(changes)}
            id={"diff-#{step.id}-#{change_index}"}
            path={change.path}
            diff={change.diff}
            line_refs={@line_refs}
          />
        </article>
      </div>

      <.review_panel
        task={@task}
        steps={@steps}
        selected_steps={@selected_steps}
        line_refs={@line_refs}
        comment={@comment}
      />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :path, :string, required: true
  attr :diff, Diff, required: true
  attr :line_refs, :list, required: true

  defp diff_file(assigns) do
    ~H"""
    <div id={@id} class="border-t border-(--orpheus-border)">
      <div class="diff-file-header flex items-center gap-2 px-4 py-2 text-xs">
        <button
          type="button"
          phx-click={
            JS.toggle(to: "##{@id}-body")
            |> JS.toggle_class("-rotate-90", to: "##{@id}-chevron")
          }
          aria-label={"Collapse #{@path}"}
          class="btn btn-ghost btn-xs btn-square"
        >
          <span id={"#{@id}-chevron"} class="flex transition-transform">
            <.icon name="hero-chevron-down-micro" class="size-4" />
          </span>
        </button>
        <.icon name="hero-document-text-micro" class="size-4 text-(--orpheus-text-muted)" />
        <code class="min-w-0 truncate font-medium">{@path}</code>
        <span class="ml-auto flex shrink-0 gap-2 font-mono tabular-nums">
          <span class="diff-stat-addition">+{@diff.additions}</span>
          <span class="diff-stat-deletion">−{@diff.deletions}</span>
        </span>
      </div>
      <div id={"#{@id}-body"} class="overflow-x-auto">
        <table class="diff-table">
          <tbody :for={{hunk, hunk_index} <- Enum.with_index(@diff.hunks)}>
            <tr :if={hunk.header} class="diff-hunk">
              <td class="diff-num"></td>
              <td class="diff-num"></td>
              <td class="diff-code">{hunk.header}</td>
            </tr>
            <%= for {line, line_index} <- Enum.with_index(hunk.lines) do %>
              <tr :if={line.kind == :note} class="diff-note">
                <td class="diff-num"></td>
                <td class="diff-num"></td>
                <td class="diff-code">{line.text}</td>
              </tr>
              <tr
                :if={line.kind != :note}
                id={"#{@id}-line-#{hunk_index}-#{line_index}"}
                data-ref={line_ref(@path, line)}
                phx-click="toggle_line"
                phx-value-ref={line_ref(@path, line)}
                title={"Reference #{line_ref(@path, line)} in your comment"}
                class={[
                  "diff-line diff-#{line.kind}",
                  line_ref(@path, line) in @line_refs && "diff-selected"
                ]}
              >
                <td class="diff-num">{line.old}</td>
                <td class="diff-num">{line.new}</td>
                <td class="diff-code"><span class="diff-sign">{sign(line.kind)}</span>{line.text}</td>
              </tr>
            <% end %>
          </tbody>
        </table>
        <p :if={@diff.hunks == []} class="px-4 py-3 text-xs text-(--orpheus-text-muted)">
          Empty diff.
        </p>
      </div>
    </div>
    """
  end

  defp sign(:addition), do: "+"
  defp sign(:deletion), do: "-"
  defp sign(:context), do: " "

  attr :task, :map, required: true
  attr :steps, :list, required: true
  attr :selected_steps, :any, required: true
  attr :line_refs, :list, required: true
  attr :comment, :string, required: true

  defp review_panel(assigns) do
    assigns =
      assign(assigns,
        open?: awaiting_plan_review?(assigns.task),
        selected?: MapSet.size(assigns.selected_steps) > 0 or assigns.line_refs != []
      )

    ~H"""
    <%!-- Below xl it sits over the plan, so it stays a one-line bar until opened. --%>
    <aside
      id="review-panel"
      class="orpheus-card sticky bottom-4 z-10 px-4 py-3 shadow-xl xl:top-6 xl:bottom-auto xl:p-4 xl:shadow-none"
    >
      <div class="flex items-center justify-between gap-3">
        <button
          id="review-panel-toggle"
          type="button"
          phx-click={
            JS.toggle_class("hidden", to: "#review-panel-body")
            |> JS.toggle_class("rotate-180", to: "#review-panel-chevron")
            |> JS.toggle_attribute({"aria-expanded", "true", "false"})
          }
          aria-expanded="false"
          aria-controls="review-panel-body"
          class="flex min-w-0 flex-1 items-center gap-2 text-left xl:pointer-events-none"
        >
          <h2 class="font-semibold">Request changes</h2>
          <span
            :if={@selected?}
            id="review-panel-count"
            class="border border-primary/50 bg-primary/10 px-1 text-[11px] leading-4 text-primary tabular-nums"
          >
            {MapSet.size(@selected_steps) + length(@line_refs)}
          </span>
          <span
            id="review-panel-chevron"
            class="ml-auto flex text-(--orpheus-text-muted) transition-transform xl:hidden"
          >
            <.icon name="hero-chevron-up-micro" class="size-4" />
          </span>
        </button>
        <button
          :if={@selected?}
          id="clear-selection"
          type="button"
          phx-click="clear_selection"
          class="text-xs text-(--orpheus-text-muted) hover:text-base-content"
        >
          Clear
        </button>
      </div>

      <div id="review-panel-body" class="mt-3 hidden xl:block">
        <div
          :if={@open?}
          id="comment-references"
          class="mb-3 flex min-h-7 flex-wrap gap-1.5"
        >
          <button
            :for={step <- @steps}
            :if={MapSet.member?(@selected_steps, step.step.id)}
            id={"chip-step-#{step.step.id}"}
            type="button"
            phx-click="toggle_step"
            phx-value-id={step.step.id}
            class="group inline-flex max-w-full items-center gap-1 border border-primary/40 bg-primary/10 py-0.5 pr-1 pl-1.5 text-xs text-primary transition-colors hover:border-primary hover:bg-primary/20"
          >
            <.icon name="hero-map-pin-micro" class="size-3.5 shrink-0" />
            <span class="truncate">{step_title(@steps, step.step.id)}</span>
            <.icon
              name="hero-x-mark-micro"
              class="size-3.5 shrink-0 opacity-60 group-hover:opacity-100"
            />
          </button>
          <button
            :for={ref <- @line_refs}
            id={"chip-line-#{ref}"}
            type="button"
            phx-click="toggle_line"
            phx-value-ref={ref}
            class="group inline-flex max-w-full items-center gap-1 border border-(--orpheus-border-strong) bg-base-200 py-0.5 pr-1 pl-1.5 font-mono text-[11px] transition-colors hover:border-base-content hover:bg-(--orpheus-hover)"
          >
            <span class="truncate">{ref}</span>
            <.icon
              name="hero-x-mark-micro"
              class="size-3.5 shrink-0 opacity-60 group-hover:opacity-100"
            />
          </button>
          <p :if={!@selected?} class="text-xs text-(--orpheus-text-muted)">
            Tick steps or click diff lines to point the planner at them.
          </p>
        </div>

        <.form
          :if={@open?}
          for={to_form(%{"body" => @comment}, as: :comment)}
          id="comment-form"
          phx-change="comment_change"
          phx-submit="request_changes"
        >
          <textarea
            id="comment-body"
            name="comment[body]"
            rows="6"
            placeholder="What should the planner change?"
            phx-debounce="300"
            class="textarea w-full resize-y text-sm"
          >{@comment}</textarea>
          <button
            id="request-changes"
            type="submit"
            phx-disable-with="Sending…"
            class="btn btn-sm mt-3 w-full border-(--orpheus-border) transition-colors hover:border-primary/60"
          >
            <.icon name="hero-chat-bubble-left-ellipsis-micro" class="size-4" /> Request changes
          </button>
        </.form>

        <div :if={!@open?} id="review-closed" class="text-sm text-(--orpheus-text-muted)">
          <%= cond do %>
            <% @task.stage == :planning and @task.status in [:todo, :in_progress] -> %>
              <div class="flex items-center gap-2">
                <.spinner class="size-3.5 text-primary" /> The planner is revising the plan…
              </div>
              <textarea
                disabled
                rows="4"
                placeholder="You can comment again once the new plan is ready."
                class="textarea mt-3 w-full text-sm"
              ></textarea>
            <% @task.plan_approved_at -> %>
              <p class="flex items-center gap-2">
                <.icon name="hero-check-badge" class="size-5 text-success" />
                Approved {timestamp(@task.plan_approved_at)}; the plan is with the coder.
              </p>
            <% true -> %>
              <p>Comments open while the plan waits for you.</p>
          <% end %>
        </div>
      </div>
    </aside>
    """
  end

  ## Decisions

  attr :task, :map, required: true
  attr :answers, :map, required: true

  defp questions_tab(%{task: %{open_questions: []}} = assigns) do
    ~H"""
    <section id="questions-panel" class="orpheus-card max-w-3xl px-6 py-16 text-center">
      <.icon name="hero-check-circle" class="mx-auto mb-3 size-8 text-(--orpheus-text-muted)" />
      <p class="font-medium">No open decisions</p>
      <p class="mt-1 text-sm text-(--orpheus-text-muted)">
        When the planner or the coder needs you to decide something, it asks here.
      </p>
    </section>
    """
  end

  defp questions_tab(assigns) do
    assigns = assign(assigns, answerable?: answerable?(assigns.task))

    ~H"""
    <section id="questions-panel" class="max-w-3xl">
      <p class="mb-4 text-sm text-(--orpheus-text-secondary)">
        {agent_name(@task.stage)} asks. Pick an option or write your own answer; it resumes once all are answered.
      </p>
      <.form
        for={%{}}
        as={:answers}
        id="answers-form"
        phx-change="answers_change"
        phx-submit="answer"
        class="space-y-4"
      >
        <fieldset
          :for={{question, index} <- Enum.with_index(@task.open_questions, 1)}
          id={"question-#{question.id}"}
          disabled={!@answerable?}
          class="orpheus-card p-5"
        >
          <legend class="sr-only">{question.question}</legend>
          <p class="mb-3 flex gap-2 font-medium">
            <span class="text-(--orpheus-text-muted) tabular-nums">{index}.</span>
            {question.question}
          </p>
          <div class="grid gap-2 sm:grid-cols-2">
            <label
              :for={{option, option_index} <- Enum.with_index(question.options)}
              id={"question-#{question.id}-option-#{option_index}"}
              class={[
                "flex cursor-pointer items-center gap-3 rounded-md border border-(--orpheus-border) px-3 py-2 text-sm transition-colors",
                "hover:border-primary/40 hover:bg-(--orpheus-hover) has-checked:border-primary has-checked:bg-primary/10"
              ]}
            >
              <input
                type="radio"
                name={"answers[#{question.id}][choice]"}
                value={option}
                checked={checked_choice?(@answers, question.id, option)}
                class="radio radio-sm radio-primary"
              />
              {option}
            </label>
          </div>
          <input
            type="text"
            id={"question-#{question.id}-other"}
            name={"answers[#{question.id}][other]"}
            value={other_answer(@answers, question.id)}
            placeholder={
              if question.options == [], do: "Your answer", else: "Or write your own answer"
            }
            phx-debounce="300"
            class="input input-sm mt-3 w-full"
          />
        </fieldset>
        <div class="flex justify-end">
          <button
            id="send-answers"
            type="submit"
            disabled={!@answerable?}
            phx-disable-with="Sending…"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-paper-airplane-micro" class="size-4" /> Send answers
          </button>
        </div>
      </.form>
    </section>
    """
  end

  ## Findings

  # A reviewer that runs twice in a round (a loop, or two blocks in its role) may name two
  # findings alike: later ones get a count, so every element keeps its own id.
  defp finding_ids(findings) do
    findings
    |> Enum.map_reduce(%{}, fn finding, seen ->
      base = "finding-#{finding.source}-#{finding.id}"
      count = Map.get(seen, base, 0) + 1
      {{finding, if(count == 1, do: base, else: "#{base}-#{count}")}, Map.put(seen, base, count)}
    end)
    |> elem(0)
  end

  attr :task, :map, required: true
  attr :max_fix_rounds, :integer, required: true

  defp findings_tab(assigns) do
    ~H"""
    <section id="findings-panel" class="max-w-4xl">
      <div class="mb-4 flex flex-wrap items-center gap-3 text-sm">
        <span id="review-round" class="orpheus-badge tone-violet">
          Fix round {@task.review_round} of {@max_fix_rounds}
        </span>
        <span
          :for={severity <- [:high, :medium, :low]}
          :if={Enum.any?(@task.findings, &(&1.severity == severity))}
          class={["orpheus-badge", "tone-#{severity_tone(severity)}"]}
        >
          {Enum.count(@task.findings, &(&1.severity == severity))} {severity}
        </span>
      </div>

      <div
        :if={@task.findings == []}
        class="orpheus-card px-6 py-16 text-center"
      >
        <.icon name="hero-shield-check" class="mx-auto mb-3 size-8 text-(--orpheus-text-muted)" />
        <p class="font-medium">No findings</p>
        <p class="mt-1 text-sm text-(--orpheus-text-muted)">
          The code reviewer and the docker reviewer report here after the coder finishes.
        </p>
      </div>

      <div class="space-y-3">
        <article
          :for={{finding, dom_id} <- finding_ids(@task.findings)}
          id={dom_id}
          class={[
            "orpheus-card overflow-hidden shadow-[inset_3px_0_0_var(--tone)]",
            "tone-#{severity_tone(finding.severity)}"
          ]}
        >
          <header class="flex flex-wrap items-center gap-2 border-b border-(--orpheus-border) px-4 py-3">
            <span class={[
              "orpheus-badge uppercase",
              "tone-#{severity_tone(finding.severity)}"
            ]}>
              {finding.severity}
            </span>
            <h3 class="min-w-0 flex-1 font-semibold">{finding.title}</h3>
            <span class="orpheus-badge tone-slate">{source_label(finding.source)}</span>
          </header>
          <div class="space-y-3 px-4 py-3 text-sm">
            <p :if={finding.path} class="flex items-center gap-1.5">
              <.icon name="hero-document-text-micro" class="size-4 text-(--orpheus-text-muted)" />
              <code class="text-xs">{finding.path}{finding.line && ":#{finding.line}"}</code>
            </p>
            <.markdown
              :if={finding.details}
              content={finding.details}
              class="text-(--orpheus-text-secondary)"
            />
            <div :if={finding.reproduction}>
              <p class="micro-label mb-1">Reproduction</p>
              <pre class="finding-pre">{finding.reproduction}</pre>
            </div>
            <div :if={finding.evidence}>
              <p class="micro-label mb-1">Evidence</p>
              <pre class="finding-pre">{finding.evidence}</pre>
            </div>
          </div>
        </article>
      </div>
    </section>
    """
  end

  ## Ask

  attr :task, :map, required: true
  attr :streams, :any, required: true
  attr :steps, :list, required: true
  attr :question, :string, required: true
  attr :pending_asks, :integer, required: true
  attr :answerer, :any, required: true
  attr :default_answerer?, :boolean, default: false

  defp ask_tab(assigns) do
    ~H"""
    <section id="ask-panel" class="max-w-3xl space-y-5">
      <ol id="ask-thread" phx-update="stream" class="space-y-5">
        <li
          id="ask-thread-empty"
          class="orpheus-card hidden px-6 py-12 text-center only:block"
        >
          <.icon name="hero-sparkles" class="mx-auto mb-3 size-8 text-(--orpheus-text-muted)" />
          <p class="font-medium">Ask about this task</p>
          <p class="mx-auto mt-1 max-w-md text-sm text-(--orpheus-text-muted)">
            Why a step is planned the way it is, what the coder changed, where a finding comes
            from. The answer comes from {asked_context(@task, @answerer)}; the task's own agents carry on undisturbed.
          </p>
        </li>
        <li :for={{id, message} <- @streams.thread} id={id} class="flex gap-3">
          <.message message={message} steps={@steps} />
        </li>
      </ol>

      <div
        :if={@pending_asks > 0}
        id="ask-pending"
        class="flex items-center gap-3 border border-primary/40 border-l-2 border-l-primary bg-primary/5 px-4 py-3 text-sm"
      >
        <.spinner class="size-4 text-primary" />
        <span>
          <span class="font-medium">{if @answerer, do: @answerer.employee.name, else: "The agent"}</span>
          is looking into {if @pending_asks == 1,
            do: "your question",
            else: "#{@pending_asks} questions"}…
          <span class="text-(--orpheus-text-muted)">The answer appears here.</span>
        </span>
      </div>

      <.form
        for={to_form(%{"body" => @question}, as: :ask)}
        id="ask-form"
        phx-change="question_change"
        phx-submit="ask"
        class="orpheus-card p-4 transition-shadow focus-within:shadow-[0_0_0_1px_var(--color-primary)]"
      >
        <label for="ask-body" class="sr-only">Your question</label>
        <textarea
          id="ask-body"
          name="ask[body]"
          rows="3"
          disabled={is_nil(@answerer) and not @default_answerer?}
          placeholder="Ask anything about this task…"
          phx-debounce="300"
          class="block w-full resize-none bg-transparent text-sm leading-relaxed outline-none placeholder:text-(--orpheus-text-muted) disabled:cursor-not-allowed"
        >{@question}</textarea>
        <div class="mt-3 flex flex-wrap items-center justify-between gap-3 border-t border-(--orpheus-border) pt-3">
          <p id="ask-hint" class="min-w-0 flex-1 text-xs text-(--orpheus-text-muted)">
            <%= cond do %>
              <% @answerer -> %>
                {@answerer.employee.name} answers from {asked_context(@task, @answerer)}, read-only.
              <% @default_answerer? -> %>
                <span id="default-answerer" class="inline-flex items-center gap-1">
                  <.icon name="hero-sparkles-micro" class="size-3.5" />
                  A default planner is created on your connector to answer, read-only.
                </span>
              <% true -> %>
                No agent can answer yet. <.link navigate={~p"/employees"} class="text-primary underline">Set up a planner or reviewer</.link>.
            <% end %>
          </p>
          <button
            id="ask-submit"
            type="submit"
            disabled={is_nil(@answerer) and not @default_answerer?}
            phx-disable-with="Asking…"
            class="btn btn-primary btn-sm shadow-sm shadow-primary/30 transition-transform active:scale-[0.98]"
          >
            <.icon name="hero-paper-airplane-micro" class="size-4" /> Ask
          </button>
        </div>
      </.form>
    </section>
    """
  end

  ## Activity

  attr :message, :map, required: true
  attr :steps, :list, required: true

  defp message(assigns) do
    ~H"""
    <span class={[
      "mt-0.5 flex size-8 shrink-0 items-center justify-center border",
      cond do
        @message.kind in [:system, :unanswered] -> "border-error/40 bg-error/10 text-error"
        @message.author == :human -> "border-primary/40 bg-primary/10 text-primary"
        true -> "border-(--orpheus-border) bg-base-200 text-(--orpheus-text-secondary)"
      end
    ]}>
      <.icon
        name={if @message.author == :human, do: "hero-user-micro", else: "hero-cpu-chip-micro"}
        class="size-4"
      />
    </span>
    <div class="min-w-0 flex-1">
      <p class="mb-1 flex flex-wrap items-baseline gap-x-2 text-sm">
        <span class="font-medium">{author_label(@message)}</span>
        <span class="text-(--orpheus-text-muted)">{kind_label(@message.kind)}</span>
        <span class="ml-auto text-[11px] text-(--orpheus-text-muted) tabular-nums">
          {timestamp(@message.inserted_at)}
        </span>
      </p>
      <div class={[
        "border px-4 py-3 text-sm",
        cond do
          @message.kind in [:system, :unanswered] -> "border-error/30 bg-error/5"
          @message.author == :human -> "border-primary/25 bg-primary/5"
          true -> "border-(--orpheus-border) bg-(--orpheus-card)"
        end
      ]}>
        <div :if={@message.step_ids != []} class="mb-2 flex flex-wrap gap-1.5">
          <span
            :for={step_id <- @message.step_ids}
            class="inline-flex items-center gap-1 border border-primary/40 bg-primary/10 px-1.5 py-0.5 text-xs text-primary"
          >
            <.icon name="hero-map-pin-micro" class="size-3.5" />
            {step_title(@steps, step_id)}
          </span>
        </div>
        <.markdown content={ErrorText.clean(@message.body)} />
      </div>
    </div>
    """
  end
end
