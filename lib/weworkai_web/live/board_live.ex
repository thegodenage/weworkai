defmodule WeworkaiWeb.BoardLive do
  use WeworkaiWeb, :live_view

  alias Weworkai.{Board, ErrorText, Organization, Workflows}
  alias Weworkai.Agents.Errors.NotRunnable
  alias Weworkai.Board.Errors.{NoAgent, NoWorktree}
  alias Weworkai.Workflows.Errors.{Refused, WorktreeRefused}
  alias Weworkai.Board.{Task, TaskAttachment}
  alias Weworkai.Board.Task.{Activity, Status}
  alias WeworkaiWeb.FolderPicker

  import WeworkaiWeb.TaskComponents

  # Search text, workflow id, assignee id ("none": nobody) and block label; "" lets all through.
  @no_filters %{"q" => "", "workflow" => "", "assignee" => "", "block" => ""}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Weworkai.PubSub, "tasks")

    workflows = Workflows.list_workflows!()

    socket =
      socket
      |> assign(
        page_title: "Board",
        statuses: Status.values(),
        workflows: workflows,
        employees: Organization.list_all_employees!(),
        block_labels: block_labels(workflows),
        filters: @no_filters
      )
      |> show_tasks()
      |> allow_upload(:attachments,
        accept: :any,
        max_entries: 10,
        max_file_size: TaskAttachment.max_file_bytes(),
        auto_upload: true,
        progress: &attach_uploaded/3
      )
      |> assign(uploads_consumed?: false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket = close_uploads(socket)
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket,
      page_title: "Board",
      form: nil,
      task: nil,
      details_form: nil,
      continue_targets: [],
      attachments: []
    )
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New task",
      form:
        to_form(
          Board.form_to_create_task(
            params: %{
              "repository" => Task.default_repository(),
              "workflow_id" => Workflows.default_workflow!().id
            }
          )
        ),
      task: nil,
      details_form: nil,
      continue_targets: [],
      attachments: []
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Board.get_task(id) do
      {:ok, task} ->
        socket
        |> assign(
          page_title: task.title,
          form: nil,
          details_form: to_form(Board.form_to_update_task(task)),
          attachments: Board.list_attachments!(task.id)
        )
        |> assign_drawer_task(task)

      {:error, _} ->
        socket
        |> put_flash(:error, "Task not found.")
        |> push_patch(to: ~p"/")
    end
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("create", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, task} ->
        {:noreply,
         socket
         |> attach_files(task)
         |> assign(uploads_consumed?: true)
         |> place(task)
         |> push_patch(to: ~p"/")}

      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("filter", %{"filter" => params}, socket) do
    filters = Map.merge(@no_filters, Map.take(params, Map.keys(@no_filters)))
    {:noreply, socket |> assign(filters: filters) |> show_tasks()}
  end

  def handle_event("clear_filters", _params, socket),
    do: {:noreply, socket |> assign(filters: @no_filters) |> show_tasks()}

  def handle_event("move", %{"task_id" => id, "status" => status}, socket) do
    with {:ok, task} <- Board.get_task(id),
         {:ok, moved} <- Board.move_task(task, status) do
      {:noreply, place(socket, moved)}
    else
      {:error, error} -> {:noreply, put_flash(socket, :error, move_error(error))}
    end
  end

  def handle_event("continue", %{"id" => id, "target" => target}, socket) do
    with {:ok, task} <- Board.get_task(id),
         {:ok, continued} <- Board.continue_task(task, target) do
      {:noreply,
       socket |> place(continued) |> put_flash(:info, "Continued. It moves on shortly.")}
    else
      {:error, error} -> {:noreply, put_flash(socket, :error, continue_error(error))}
    end
  end

  def handle_event("save_details", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.details_form, params: params) do
      {:ok, task} ->
        {:noreply,
         socket
         |> place(task)
         |> assign(page_title: task.title, details_form: to_form(Board.form_to_update_task(task)))}

      {:error, form} ->
        {:noreply, assign(socket, details_form: form)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, task} <- Board.get_task(id),
         :ok <- Board.destroy_task(task) do
      {:noreply,
       socket
       |> stream_delete(task.status, task)
       |> update(:placements, &Map.delete(&1, task.id))
       |> update(:working, &Map.delete(&1, task.id))
       |> update(:shown, &MapSet.delete(&1, task.id))
       |> put_flash(:info, "Task deleted.")
       |> push_patch(to: ~p"/")}
    else
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not delete the task.")}
    end
  end

  def handle_event("validate_attachments", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  def handle_event("remove_attachment", %{"id" => id}, socket) do
    socket.assigns.attachments |> Enum.find(&(&1.id == id)) |> Board.remove_attachment!()
    {:noreply, assign(socket, attachments: Board.list_attachments!(socket.assigns.task.id))}
  end

  # The workflow moves tasks too; whatever changed a task, its card follows.
  @impl true
  def handle_info({:task_updated, %{id: id}}, socket) do
    case Board.get_task(id) do
      {:ok, task} -> {:noreply, socket |> place(task) |> replace(related(task))}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_info({:task_deleted, task}, socket) do
    socket =
      case Map.fetch(socket.assigns.placements, task.id) do
        {:ok, status} ->
          socket
          |> stream_delete(status, task)
          |> update(:placements, &Map.delete(&1, task.id))
          |> update(:working, &Map.delete(&1, task.id))
          |> update(:shown, &MapSet.delete(&1, task.id))

        :error ->
          socket
      end

    if socket.assigns.task && socket.assigns.task.id == task.id do
      {:noreply, socket |> put_flash(:error, "This task was deleted.") |> push_patch(to: ~p"/")}
    else
      {:noreply, socket}
    end
  end

  # Idempotent, so a change this view made itself and then hears about again is harmless.
  # Actions return the task without its activity, which the card shows. A task the filters
  # no longer let through leaves the board.
  defp place(socket, task) do
    task =
      task
      |> Ash.load!(:activity, lazy?: true)
      |> Ash.load!(
        [:current_node, :open_blocker_titles, :dependent_ids, :child_count, :done_child_count],
        lazy?: true
      )

    previous = socket.assigns.placements[task.id]

    socket
    |> then(&if(previous in [nil, task.status], do: &1, else: stream_delete(&1, previous, task)))
    |> show_card(task)
    |> update(:placements, &Map.put(&1, task.id, task.status))
    |> update(:working, &track_working(&1, task))
    |> then(
      &if(&1.assigns.task && &1.assigns.task.id == task.id,
        do: assign_drawer_task(&1, task),
        else: &1
      )
    )
  end

  # A task's dependents show it as their blocker, its parent counts it as a sub-task.
  defp related(task), do: Enum.reject([task.parent_id | task.dependent_ids], &is_nil/1)

  defp replace(socket, ids) do
    ids
    |> Enum.filter(&Map.has_key?(socket.assigns.placements, &1))
    |> Enum.reduce(socket, fn id, socket -> place(socket, Board.get_task!(id)) end)
  end

  defp show_card(socket, task) do
    if matches?(task, socket.assigns.filters) do
      socket |> stream_insert(task.status, task) |> update(:shown, &MapSet.put(&1, task.id))
    else
      socket |> stream_delete(task.status, task) |> update(:shown, &MapSet.delete(&1, task.id))
    end
  end

  # Fills every column afresh with the tasks the filters let through. placements and
  # working keep every task: moves need the old column, the "Needs you" banner counts all.
  defp show_tasks(socket) do
    tasks = Board.list_tasks!()
    shown = Enum.filter(tasks, &matches?(&1, socket.assigns.filters))
    by_status = Enum.group_by(shown, & &1.status)

    socket.assigns.statuses
    |> Enum.reduce(socket, &stream(&2, &1, Map.get(by_status, &1, []), reset: true))
    |> assign(
      # The column each card is in; streams don't remember, and moves need the old column.
      placements: Map.new(tasks, &{&1.id, &1.status}),
      # Whether an agent runs or is queued on each card it works on, for the columns' counts.
      working: Map.new(Enum.filter(tasks, & &1.activity), &{&1.id, &1.activity.state}),
      shown: MapSet.new(shown, & &1.id)
    )
  end

  defp matches?(task, filters) do
    text?(task, filters["q"]) and filters["workflow"] in ["", task.workflow_id] and
      assignee?(filters["assignee"], task.assignee_id) and
      block?(filters["block"], task.current_node)
  end

  defp text?(task, query) do
    case String.downcase(String.trim(query)) do
      "" -> true
      query -> String.contains?(String.downcase("#{task.title} #{task.description}"), query)
    end
  end

  defp assignee?("", _assignee_id), do: true
  defp assignee?("none", assignee_id), do: is_nil(assignee_id)
  defp assignee?(wanted, assignee_id), do: wanted == assignee_id

  defp block?("", _node), do: true
  defp block?(label, %{label: label}), do: true
  defp block?(_label, _node), do: false

  defp filtering?(filters), do: filters != @no_filters

  # Labels of the blocks a task can sit on, across workflows: "Code review" finds a task on
  # such a block whichever workflow it runs.
  defp block_labels(workflows) do
    workflows
    |> Enum.flat_map(&Map.values(Workflows.graph!(&1.id).nodes))
    |> Enum.reject(&(&1.kind == :group))
    |> Enum.map(& &1.label)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp assign_drawer_task(socket, task) do
    task = Ash.load!(task, :activity, lazy?: true)
    assign(socket, task: task, continue_targets: Board.continue_targets(task))
  end

  defp count(placements, status),
    do: Enum.count(placements, fn {_id, in_status} -> in_status == status end)

  # Cards shown in the column: the filters' count, not the column's whole.
  defp shown_count(placements, shown, status),
    do: Enum.count(shown, &(placements[&1] == status))

  defp track_working(working, %{activity: nil} = task), do: Map.delete(working, task.id)
  defp track_working(working, task), do: Map.put(working, task.id, task.activity.state)

  # Shown cards in the column whose agent is running now (queued ones only pulse).
  defp running(working, placements, shown, status) do
    Enum.count(working, fn {id, state} ->
      state == :running and placements[id] == status and MapSet.member?(shown, id)
    end)
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  # The card's left rule: amber while it waits for a person, the accent while an agent runs.
  defp card_tone(%{status: :await_human_supervision}), do: "tone-amber"
  defp card_tone(%{activity: %{state: :running}}), do: "tone-accent"
  defp card_tone(_task), do: nil

  defp move_error(%Ash.Error.Invalid{errors: [%type{} | _]} = error)
       when type in [NotRunnable, NoAgent, NoWorktree, Refused, WorktreeRefused],
       do: ErrorText.readable(error)

  defp move_error(_error), do: "Could not move the task."

  # A workflow saved with problems can be picked, but runs nothing until they are fixed.
  defp workflow_options(workflows), do: Enum.map(workflows, &{workflow_option(&1), &1.id})

  defp workflow_option(%{problem_count: 0, name: name}), do: name
  defp workflow_option(%{name: name}), do: "#{name} (has problems)"

  # Switching workflows starts a task over (Task.Changes.SwitchWorkflow): worth a question
  # once it is somewhere in its workflow, all the more while an agent works on it.
  defp switch_warning(%{current_node_id: nil}), do: nil

  defp switch_warning(task) do
    stops =
      if Activity.workflow?(task.activity),
        do: " and stops the agent working on it",
        else: ""

    "Another workflow starts “#{task.title}” over from its start block#{stops}. Switch?"
  end

  # Files picked in a closed modal or drawer must not attach to the next task opened. Files
  # "create" just consumed stay listed until LiveView drops them after this callback, and
  # their upload channels have exited, so canceling them would crash the view.
  defp close_uploads(%{assigns: %{uploads_consumed?: true}} = socket),
    do: assign(socket, uploads_consumed?: false)

  defp close_uploads(socket), do: cancel_uploads(socket)

  defp cancel_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.attachments.entries, socket, fn entry, socket ->
      cancel_upload(socket, :attachments, entry.ref)
    end)
  end

  # The drawer attaches a file as soon as it is uploaded; a new task's files wait for "create".
  defp attach_uploaded(
         :attachments,
         %{done?: true} = entry,
         %{assigns: %{task: %Task{} = task}} = socket
       ) do
    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, attach(task, path, entry)}
      end)

    socket =
      case result do
        {:ok, _attachment} -> socket
        {:error, _error} -> put_flash(socket, :error, not_attached([entry.client_name]))
      end

    {:noreply, assign(socket, attachments: Board.list_attachments!(task.id))}
  end

  defp attach_uploaded(:attachments, _entry, socket), do: {:noreply, socket}

  defp attach_files(socket, task) do
    failed =
      socket
      |> consume_uploaded_entries(:attachments, fn %{path: path}, entry ->
        {:ok, {entry.client_name, attach(task, path, entry)}}
      end)
      |> Enum.flat_map(fn
        {_name, {:ok, _attachment}} -> []
        {name, {:error, _error}} -> [name]
      end)

    if failed == [], do: socket, else: put_flash(socket, :error, not_attached(failed))
  end

  defp attach(task, path, entry) do
    Board.attach_file(%{
      task_id: task.id,
      file_name: entry.client_name,
      content: File.read!(path)
    })
  end

  defp not_attached(names) do
    limit = div(TaskAttachment.max_task_bytes(), 1_000_000)
    "Not attached: #{Enum.join(names, ", ")}. A task's files total at most #{limit} MB."
  end

  defp uploading?(upload), do: Enum.any?(upload.entries, &(not &1.done?))

  # Lets the description's preview show the attachments it references by name.
  defp attachment_urls(attachments),
    do: Map.new(attachments, &{&1.name, ~p"/attachments/#{&1.id}"})

  defp file_size(bytes) when bytes < 1_000, do: "#{bytes} B"
  defp file_size(bytes) when bytes < 1_000_000, do: "#{div(bytes, 1_000)} KB"
  defp file_size(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  defp upload_error(:too_large),
    do: "Larger than #{div(TaskAttachment.max_file_bytes(), 1_000_000)} MB"

  defp upload_error(:too_many_files), do: "At most 10 files at a time"
  defp upload_error(_error), do: "Could not upload"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:kanban}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <div class="mb-6 flex items-end justify-between gap-3 border-b border-(--orpheus-border) pb-4">
        <div>
          <p class="micro-label mb-1">~/board</p>
          <h1 class="text-2xl font-semibold tracking-tight">Board</h1>
        </div>
        <%!-- Its column sits right of the fold on most screens: this jumps the board there. --%>
        <a
          :if={count(@placements, :await_human_supervision) > 0}
          id="board-needs-you"
          href="#board-column-await_human_supervision"
          class="mr-auto mb-0.5 transition-transform hover:-translate-y-px"
        >
          <.needs_you id="board-needs-you-badge" />
          <span class="sr-only">: </span>
          <span class="ml-0.5 text-xs font-medium text-(--orpheus-text-secondary)">
            {count(@placements, :await_human_supervision)}
            {if count(@placements, :await_human_supervision) == 1, do: "task", else: "tasks"}
          </span>
        </a>
        <.button
          id="new-task"
          patch={~p"/tasks/new"}
          variant="primary"
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-plus-micro" class="size-4" /> New
        </.button>
      </div>

      <form
        id="board-filters"
        phx-change="filter"
        phx-submit="filter"
        class="mb-4 flex flex-wrap items-center gap-2"
      >
        <label class="input input-sm w-64">
          <.icon name="hero-magnifying-glass-micro" class="size-4 opacity-60" />
          <input
            id="board-filter-q"
            type="search"
            name="filter[q]"
            value={@filters["q"]}
            placeholder="Search tasks…"
            aria-label="Search tasks"
            autocomplete="off"
            phx-debounce="200"
            class="grow"
          />
        </label>
        <select
          id="board-filter-workflow"
          name="filter[workflow]"
          aria-label="Workflow"
          class="select select-sm w-44"
        >
          <option value="">All workflows</option>
          {Phoenix.HTML.Form.options_for_select(
            Enum.map(@workflows, &{&1.name, &1.id}),
            @filters["workflow"]
          )}
        </select>
        <select
          id="board-filter-assignee"
          name="filter[assignee]"
          aria-label="Assignee"
          class="select select-sm w-44"
        >
          <option value="">Anyone</option>
          {Phoenix.HTML.Form.options_for_select(
            [{"Nobody", "none"} | Enum.map(@employees, &{&1.name, &1.id})],
            @filters["assignee"]
          )}
        </select>
        <select
          id="board-filter-block"
          name="filter[block]"
          aria-label="Block"
          class="select select-sm w-44"
        >
          <option value="">Any block</option>
          {Phoenix.HTML.Form.options_for_select(@block_labels, @filters["block"])}
        </select>
        <button
          :if={filtering?(@filters)}
          id="board-filters-clear"
          type="button"
          phx-click="clear_filters"
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-x-mark-micro" class="size-4" /> Clear
        </button>
      </form>

      <div id="board" phx-hook=".Board" class="flex scroll-smooth gap-3 overflow-x-auto pb-6">
        <section
          :for={status <- @statuses}
          id={"board-column-#{status}"}
          data-status={status}
          aria-label={Status.label(status)}
          class="board-lane w-72 shrink-0"
        >
          <header class="flex h-9 items-center gap-2 border-b border-dashed border-(--orpheus-border) px-2.5">
            <span
              aria-hidden="true"
              class={["size-1.5 shrink-0 bg-(--tone)", "tone-#{status_tone(status)}"]}
            ></span>
            <h2 class="micro-label text-(--orpheus-text-secondary)">{Status.label(status)}</h2>
            <span
              id={"board-column-#{status}-count"}
              class="micro-label tabular-nums"
            >
              [{pad(shown_count(@placements, @shown, status))}]
            </span>
            <span
              :if={running(@working, @placements, @shown, status) > 0}
              id={"board-column-#{status}-working"}
              class="ml-auto inline-flex items-center gap-1.5 text-[11px] font-medium text-primary uppercase tracking-wider"
            >
              <.spinner class="size-2.5" />
              {running(@working, @placements, @shown, status)} working
            </span>
          </header>

          <div id={"column-#{status}"} phx-update="stream" class="flex min-h-12 flex-col gap-2 p-2">
            <p
              id={"column-#{status}-empty"}
              class="micro-label hidden border border-dashed border-(--orpheus-border) px-3 py-5 text-center only:block"
            >
              {if filtering?(@filters), do: "[ No matching tasks ]", else: "[ No tasks ]"}
            </p>
            <article
              :for={{id, task} <- @streams[status]}
              id={id}
              draggable="true"
              data-task-id={task.id}
              data-working={task.activity && task.activity.state}
              class={[
                "board-card orpheus-card cursor-grab px-2.5 py-2 text-xs active:cursor-grabbing",
                card_tone(task)
              ]}
            >
              <%!-- Not draggable itself so a drag starting on the link still drags the card. --%>
              <.link
                id={"task-link-#{task.id}"}
                {card_link(task)}
                draggable="false"
                class="block"
              >
                <div
                  :if={
                    task.status == :await_human_supervision || task.activity ||
                      task.open_blocker_titles != []
                  }
                  class="mb-2 flex flex-wrap items-center gap-1.5"
                >
                  <.needs_you
                    :if={task.status == :await_human_supervision}
                    id={"needs-you-#{task.id}"}
                  />
                  <.blocked_badge
                    :if={task.open_blocker_titles != []}
                    id={"task-#{task.id}-blocked"}
                    titles={task.open_blocker_titles}
                  />
                  <.agent_activity
                    :if={task.activity}
                    id={"task-#{task.id}-working"}
                    activity={task.activity}
                  />
                </div>
                <p class="text-[13px] leading-snug font-medium break-words">{task.title}</p>
                <p
                  :if={task.description}
                  class="mt-1 line-clamp-2 break-words text-(--orpheus-text-muted)"
                >
                  {task.description}
                </p>
                <div
                  :if={task.assignee || task.stage || task.current_node || task.child_count > 0}
                  class="mt-2 flex flex-wrap items-center gap-x-2 gap-y-1 border-t border-dashed border-(--orpheus-border) pt-1.5"
                >
                  <.avatar :if={task.assignee} employee={task.assignee} />
                  <%!-- The working badge above names the stage already. --%>
                  <.stage_badge
                    :if={task.stage && !Activity.workflow?(task.activity)}
                    stage={task.stage}
                  />
                  <.block_badge
                    :if={task.current_node}
                    id={"task-#{task.id}-block"}
                    block={task.current_node}
                  />
                  <.subtask_progress
                    :if={task.child_count > 0}
                    id={"task-#{task.id}-subtasks"}
                    done={task.done_child_count}
                    total={task.child_count}
                  />
                </div>
              </.link>
            </article>
          </div>
        </section>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Board">
        export default {
          mounted() {
            let source = null
            const columnAt = (target) => target.closest("[data-status]")
            const clearHighlight = () =>
              this.el.querySelectorAll("[data-over]").forEach((el) => el.removeAttribute("data-over"))

            this.el.addEventListener("dragstart", (event) => {
              const card = event.target.closest("[data-task-id]")
              source = columnAt(card)
              card.setAttribute("data-dragging", "")
              event.dataTransfer.effectAllowed = "move"
              event.dataTransfer.setData("text/plain", card.dataset.taskId)
            })

            this.el.addEventListener("dragover", (event) => {
              const column = columnAt(event.target)
              if (!column) return
              event.preventDefault()
              if (!column.hasAttribute("data-over")) {
                clearHighlight()
                column.setAttribute("data-over", "")
              }
            })

            this.el.addEventListener("drop", (event) => {
              const column = columnAt(event.target)
              if (!column) return
              event.preventDefault()
              clearHighlight()
              if (column === source) return
              this.pushEvent("move", {
                task_id: event.dataTransfer.getData("text/plain"),
                status: column.dataset.status,
              })
            })

            this.el.addEventListener("dragend", (event) => {
              clearHighlight()
              event.target.closest("[data-task-id]")?.removeAttribute("data-dragging")
            })
          },
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ConfirmSwitch">
        // A select can't carry phx-click's data-confirm: ask before LiveView sees the change,
        // and put the old choice back when the person declines.
        export default {
          mounted() {
            this.previous = this.el.value
            const guard = (event) => {
              if (event.type === "input") {
                this.accepted = !this.el.dataset.confirm || window.confirm(this.el.dataset.confirm)
              }
              if (this.accepted) {
                if (event.type === "change") this.previous = this.el.value
                return
              }
              event.stopImmediatePropagation()
              if (event.type === "change") this.el.value = this.previous
            }
            this.el.addEventListener("input", guard)
            this.el.addEventListener("change", guard)
          },
          updated() {
            this.previous = this.el.value
          },
        }
      </script>

      <aside
        :if={@task}
        id="task-drawer"
        role="dialog"
        aria-labelledby="task-drawer-title"
        class="fixed inset-y-0 right-0 z-40 flex w-full max-w-xl flex-col overflow-y-auto border-l border-(--orpheus-border-strong) bg-(--orpheus-card) shadow-[-4px_0_0_0_var(--hard-shadow)]"
        phx-window-keydown={close_drawer()}
        phx-key="escape"
      >
        <div class="sticky top-0 z-10 flex h-11 shrink-0 items-center justify-between gap-2 border-b border-(--orpheus-border) bg-(--orpheus-card) px-3">
          <.link
            id="task-drawer-close"
            patch={~p"/"}
            class="btn btn-ghost btn-xs btn-square"
            aria-label="Close"
            title="Close (Esc)"
          >
            <.icon name="hero-chevron-double-right-micro" class="size-4" />
          </.link>
          <div class="flex items-center gap-1">
            <.link
              id="task-drawer-timeline"
              navigate={~p"/audit/#{@task.id}"}
              class="btn btn-ghost btn-xs"
            >
              <.icon name="hero-chart-bar-square-micro" class="size-4" /> Timeline
            </.link>
            <.link
              id="task-drawer-open"
              navigate={~p"/tasks/#{@task.id}"}
              class="btn btn-ghost btn-xs"
            >
              <.icon name="hero-arrows-pointing-out-micro" class="size-4" /> Open task
            </.link>
            <.continue_control
              id="task-drawer-continue"
              targets={@continue_targets}
              task_id={@task.id}
              working?={Activity.workflow?(@task.activity)}
              size="btn-xs"
            />
            <button
              id="task-drawer-delete"
              type="button"
              phx-click="delete"
              phx-value-id={@task.id}
              data-confirm={"Delete “#{@task.title}”?"}
              class="btn btn-ghost btn-xs btn-square text-error hover:bg-error/10"
              aria-label="Delete task"
              title="Delete task"
            >
              <.icon name="hero-trash-micro" class="size-4" />
            </button>
          </div>
        </div>
        <div class="px-8 pt-6 pb-12">
          <.form
            for={@details_form}
            id="task-drawer-title-form"
            phx-change="save_details"
            phx-submit="save_details"
            phx-auto-recover="ignore"
            class="mb-6"
          >
            <input
              id="task-drawer-title"
              name={@details_form[:title].name}
              value={@details_form[:title].value}
              aria-label="Title"
              placeholder="Untitled"
              phx-debounce="blur"
              class="w-full bg-transparent text-2xl font-semibold outline-none placeholder:text-(--orpheus-text-muted)"
            />
            <p
              :for={message <- Enum.map(@details_form[:title].errors, &translate_error/1)}
              class="mt-1 text-sm text-error"
            >
              Title {message}
            </p>
          </.form>
          <dl class="mb-6 grid grid-cols-[8rem_1fr] items-center gap-y-2 border-y border-dashed border-(--orpheus-border) py-4 text-sm">
            <dt class="micro-label">Status</dt>
            <dd>
              <form id="task-drawer-status" phx-change="move" phx-auto-recover="ignore">
                <input type="hidden" name="task_id" value={@task.id} />
                <select name="status" aria-label="Status" class="select select-sm w-56">
                  <option :for={option <- @statuses} value={option} selected={option == @task.status}>
                    {Status.label(option)}
                  </option>
                </select>
              </form>
            </dd>
            <%!-- The workflow assigns: whoever runs or decides the block the task is on. --%>
            <dt class="micro-label">Assignee</dt>
            <dd
              id="task-drawer-assignee"
              class="flex items-center gap-2"
              title="Set by the workflow: who works on the block the task is on"
            >
              <%= if @task.assignee do %>
                <.avatar employee={@task.assignee} />
                <span>{@task.assignee.name}</span>
              <% else %>
                <span class="text-(--orpheus-text-muted)">Nobody yet</span>
              <% end %>
            </dd>
            <dt class="micro-label">Repository</dt>
            <dd>
              <.form
                for={@details_form}
                id="task-drawer-repository-form"
                phx-change="save_details"
                phx-submit="save_details"
                phx-auto-recover="ignore"
              >
                <.live_component
                  module={FolderPicker}
                  id="task-drawer-repository"
                  field={@details_form[:repository]}
                  debounce="blur"
                  class="input input-sm w-56 font-mono"
                />
              </.form>
            </dd>
            <dt class="micro-label">Workflow</dt>
            <dd>
              <.form
                for={@details_form}
                id="task-drawer-workflow-form"
                phx-change="save_details"
                phx-auto-recover="ignore"
                class="flex items-center gap-2"
              >
                <select
                  id="task-drawer-workflow"
                  name={@details_form[:workflow_id].name}
                  aria-label="Workflow"
                  title="Another workflow starts the task over from its start block"
                  phx-hook=".ConfirmSwitch"
                  data-confirm={switch_warning(@task)}
                  class="select select-sm w-56"
                >
                  {Phoenix.HTML.Form.options_for_select(
                    workflow_options(@workflows),
                    @details_form[:workflow_id].value
                  )}
                </select>
                <.block_badge
                  :if={@task.current_node}
                  id="task-drawer-block"
                  block={@task.current_node}
                />
              </.form>
            </dd>
            <dt :if={@task.stage} class="micro-label">Stage</dt>
            <dd :if={@task.stage}><.stage_badge stage={@task.stage} /></dd>
            <dt class="micro-label">Created</dt>
            <dd>{Calendar.strftime(@task.inserted_at, "%B %-d, %Y %H:%M")}</dd>
            <dt class="micro-label">Last edited</dt>
            <dd>{Calendar.strftime(@task.updated_at, "%B %-d, %Y %H:%M")}</dd>
          </dl>
          <.form
            for={@details_form}
            id="task-drawer-description-form"
            phx-change="save_details"
            phx-auto-recover="ignore"
          >
            <.section_label class="mb-3">Description</.section_label>
            <.markdown_editor
              id="task-drawer-description"
              field={@details_form[:description]}
              upload={@uploads.attachments}
              files={attachment_urls(@attachments)}
              placeholder="Add a description… Paste a screenshot to attach it."
              rows="12"
              phx-debounce="800"
            />
          </.form>
          <section id="task-drawer-attachments" class="mt-8">
            <.section_label count={length(@attachments)}>Attachments</.section_label>
            <p class="mt-1 mb-3 text-xs text-(--orpheus-text-muted)">
              Every agent on this task finds them in its working directory.
            </p>
            <ul :if={@attachments != []} id="task-drawer-attachment-list" class="mb-3 space-y-1">
              <li
                :for={attachment <- @attachments}
                id={"attachment-#{attachment.id}"}
                class="group flex items-center gap-3 border border-transparent px-2 py-1.5 text-sm transition-colors hover:border-(--orpheus-border) hover:bg-(--orpheus-hover)"
              >
                <%= if TaskAttachment.image?(attachment.name) do %>
                  <img
                    src={~p"/attachments/#{attachment.id}"}
                    alt=""
                    loading="lazy"
                    class="size-10 shrink-0 rounded border border-(--orpheus-border) object-cover"
                  />
                <% else %>
                  <span class="flex size-10 shrink-0 items-center justify-center rounded border border-(--orpheus-border) text-(--orpheus-text-muted)">
                    <.icon name="hero-document-micro" class="size-4" />
                  </span>
                <% end %>
                <a
                  id={"download-attachment-#{attachment.id}"}
                  href={~p"/attachments/#{attachment.id}"}
                  target="_blank"
                  rel="noopener"
                  class="min-w-0 truncate transition-colors hover:text-primary hover:underline"
                >
                  {attachment.name}
                </a>
                <span class="shrink-0 text-xs text-(--orpheus-text-muted)">
                  {file_size(attachment.size)}
                </span>
                <button
                  id={"remove-attachment-#{attachment.id}"}
                  type="button"
                  phx-click="remove_attachment"
                  phx-value-id={attachment.id}
                  aria-label={"Remove #{attachment.name}"}
                  class="btn btn-ghost btn-xs btn-square ml-auto transition-opacity sm:opacity-0 sm:group-hover:opacity-100 sm:focus-visible:opacity-100"
                >
                  <.icon name="hero-x-mark-micro" class="size-4" />
                </button>
              </li>
            </ul>
            <form id="task-drawer-attachments-form" phx-change="validate_attachments">
              <.attachment_drop upload={@uploads.attachments} />
            </form>
          </section>
        </div>
      </aside>

      <.modal :if={@form} id="task-modal" on_cancel={JS.patch(~p"/")}>
        <:title>New task</:title>
        <.form for={@form} id="task-form" phx-change="validate" phx-submit="create">
          <.input
            field={@form[:title]}
            label="Title"
            placeholder="Untitled"
            phx-mounted={JS.focus()}
          />
          <.markdown_editor
            id="task-form-description"
            field={@form[:description]}
            upload={@uploads.attachments}
            label="Description"
            placeholder="Add a description… Paste a screenshot to attach it."
            rows="6"
          />
          <div class="fieldset mb-2">
            <span class="label mb-1">Attachments</span>
            <.attachment_drop upload={@uploads.attachments} />
          </div>
          <.live_component
            module={FolderPicker}
            id="task-form-repository"
            field={@form[:repository]}
            label="Repository"
          />
          <.input
            field={@form[:workflow_id]}
            type="select"
            label="Workflow"
            options={workflow_options(@workflows)}
            class="select w-full"
          />
          <p class="mb-2 text-xs text-(--orpheus-text-muted)">
            Moving the task to Todo starts its workflow; each block's agent or person takes it on.
          </p>
          <div class="mt-4 flex justify-end gap-2">
            <.button patch={~p"/"} class="btn btn-ghost btn-sm">Cancel</.button>
            <.button
              variant="primary"
              class="btn btn-primary btn-sm"
              phx-disable-with="Creating…"
              disabled={uploading?(@uploads.attachments)}
            >
              Create
            </.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  attr :upload, Phoenix.LiveView.UploadConfig, required: true

  defp attachment_drop(assigns) do
    ~H"""
    <label
      phx-drop-target={@upload.ref}
      class="flex cursor-pointer items-center justify-center gap-2 rounded-md border border-dashed border-(--orpheus-border) px-3 py-4 text-sm text-(--orpheus-text-muted) transition-colors hover:border-primary/60 hover:text-base-content phx-drop-target-active:border-primary phx-drop-target-active:bg-primary/5"
    >
      <.icon name="hero-arrow-up-tray-micro" class="size-4" />
      <span>
        Drop files, paste into the description, or <span class="text-primary">browse</span>
      </span>
      <.live_file_input upload={@upload} class="sr-only" />
    </label>
    <p :for={error <- upload_errors(@upload)} class="mt-1 text-xs text-error">
      {upload_error(error)}
    </p>
    <ul :if={@upload.entries != []} class="mt-2 space-y-1">
      <li
        :for={entry <- @upload.entries}
        id={"upload-#{entry.ref}"}
        class="flex items-center gap-2 text-sm"
      >
        <.live_img_preview
          :if={String.starts_with?(entry.client_type, "image/")}
          entry={entry}
          class="size-8 shrink-0 rounded object-cover"
        />
        <span class="min-w-0 truncate">{entry.client_name}</span>
        <%= case upload_errors(@upload, entry) do %>
          <% [] -> %>
            <progress
              value={entry.progress}
              max="100"
              class="progress progress-primary w-20 shrink-0"
            />
          <% [error | _] -> %>
            <span class="shrink-0 text-xs text-error">{upload_error(error)}</span>
        <% end %>
        <button
          id={"cancel-upload-#{entry.ref}"}
          type="button"
          phx-click="cancel_upload"
          phx-value-ref={entry.ref}
          aria-label={"Cancel #{entry.client_name}"}
          class="btn btn-ghost btn-xs btn-square ml-auto"
        >
          <.icon name="hero-x-mark-micro" class="size-4" />
        </button>
      </li>
    </ul>
    """
  end

  # Focusing away first blurs a field with a pending debounced autosave, which flushes it before the patch.
  defp close_drawer, do: JS.focus(to: "#task-drawer-close") |> JS.patch(~p"/")

  # A task with a plan, or one waiting for a human, opens its own view; others the drawer.
  defp card_link(%{plan: plan, status: status} = task)
       when not is_nil(plan) or status == :await_human_supervision,
       do: [navigate: ~p"/tasks/#{task.id}"]

  defp card_link(task), do: [patch: ~p"/tasks/#{task.id}/edit"]
end
