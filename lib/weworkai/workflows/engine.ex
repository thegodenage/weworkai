defmodule Weworkai.Workflows.Engine do
  @moduledoc """
  Runs a board task through its workflow graph (docs/workflows.md). Entering a block acts
  by its kind: an agent block queues a run for its agent (the role decides prompt, schema,
  profile and folder), a human block waits for a decision, a column block moves the task
  (done and canceled end the workflow), a group enters its first block, a triage block
  routes on the worst severity among the open findings. A run's result is
  an outcome (`plan_ready`, `needs_answers`, `done`, `blocked`, `clean`, `findings`) that
  `Graph.route/4` turns into the next arrow. Questions a human asks about the task (stage
  `ask`) are answered beside the graph, without moving the task.

  The scheduler reports every run's start, result and failure here. Each is applied in the
  same transaction as the attempt's own transition, and that transition only accepts a
  `started` attempt, so a result is consumed exactly once, even across scheduler restarts.
  Consumed runs are closed so they leave the dashboard. Human actions build their
  transition with the functions under "Human steps" (`Board.Task.Changes.Transition`).

  A transition is built outside any transaction: entering a coder block may create its
  worktree, a reviewer block asks the bridge for the diff.
  """
  alias Weworkai.{Agents, Board, Connectors, ErrorText, Notifications, Organization}
  alias Weworkai.{Scheduling, Workflows}
  alias Weworkai.Agents.Agent.Role
  alias Weworkai.Agents.Budget
  alias Weworkai.Agents.Errors.NotRunnable
  alias Weworkai.Board.Errors.{NoAgent, NoWorktree}
  alias Weworkai.Organization.DefaultAgent
  alias Weworkai.Scheduling.{StartFailure, Timeout}
  alias Weworkai.Workflows.{Graph, Prompts, Result, Transition}
  alias Weworkai.Workflows.Errors.{Refused, WorktreeRefused}

  # Blocks entered in one go (columns pass on, skipped reviewers route on) before the
  # engine gives up on a graph that goes round without doing anything.
  @max_hops 50

  @review_roles [:reviewer, :qa]

  @doc "The task stage an agent in `role` works in; nil runs the task as written."
  def stage(:planner), do: :planning
  def stage(:coder), do: :coding
  def stage(:reviewer), do: :code_review
  def stage(:qa), do: :qa
  def stage(:custom), do: nil

  @doc "Names the task's worktree, branch and docker reviewer containers."
  def short_id(task), do: String.slice(task.id, 0, 8)

  @doc "The status a task has while a job of `stage` works on it."
  def working_status(stage) when stage in [:code_review, :qa], do: :review
  def working_status(_stage), do: :in_progress

  # A human started it: queued until the scheduler picks it up; reviewers show in review.
  defp queued_status(stage) when stage in [:code_review, :qa], do: :review
  defp queued_status(_stage), do: :todo

  @doc """
  Whether the reviewers are done and the task's branch waits for a human to merge it:
  waiting for a human outside planning, with a branch, and no agent failed on the way.
  """
  def ready_to_merge?(task) do
    task.status == :await_human_supervision and is_nil(task.stage) and
      not is_nil(task.worktree_branch) and not restartable?(task)
  end

  @doc "Where every run on the task finds its attached files, relative to its working directory."
  def attachments_folder(task), do: ".weworkai/attachments/#{short_id(task)}"

  @doc """
  The task's files for its next run; the connector writes them to `attachments_folder/1`
  in the run's folder before the run starts.
  """
  def attachments(task) do
    files = Enum.map(Board.attachment_files!(task.id), &Map.take(&1, [:name, :content]))
    %{folder: short_id(task), files: files}
  end

  @doc """
  How many fix rounds the graph allows: the caps of the arrows that carry findings into a
  coder block (named `findings`, or unnamed out of a reviewer or a group, or any but `clean`
  out of a triage block). A self-loop's cap counts runs in a row, so it sends the findings
  back one time fewer.
  """
  def fix_round_limit(graph) do
    graph.edges
    |> Enum.filter(&(carries_findings?(graph, &1) and target_role(graph, &1) == :coder))
    |> Enum.map(&fix_rounds/1)
    |> Enum.sum()
  end

  defp carries_findings?(_graph, %{condition: "findings"}), do: true

  defp carries_findings?(graph, %{condition: condition, from_node_id: from}) do
    case Graph.node(graph, from).kind do
      :triage -> condition != "clean"
      :group -> is_nil(condition)
      _kind -> is_nil(condition) and Graph.role(graph, from) in @review_roles
    end
  end

  defp fix_rounds(%{from_node_id: id, to_node_id: id, iterations: runs}), do: runs - 1
  defp fix_rounds(edge), do: edge.iterations || 1

  defp target_role(graph, edge) do
    {node, _groups} = Graph.resolve(graph, edge.to_node_id)
    Graph.role(graph, node.id)
  end

  ## Questions

  @doc """
  The agent that answers questions about tasks: the first runnable planner, else reviewer.
  Both only read, so a question can never change the code. Nil when neither is set up.
  """
  def answerer, do: Enum.find_value([:planner, :reviewer], &first_runnable/1)

  defp first_runnable(role) do
    List.first(Agents.runnable_agents!(query: [filter: [role: role], sort: [id: :asc], limit: 1]))
  end

  @doc """
  Job attributes that answer `question` about the task beside its workflow. The run
  continues a copy (`fork`) of the task's latest conversation, the coder's or else the
  planner's, in the folder that conversation ran in, so the agent knows the task and its
  own conversation stays untouched. A task without one gets a fresh run told about it.
  """
  def ask_job(task, agent, question) do
    task = Ash.load!(task, :attachment_names)
    {session, folder} = asked_conversation(task, connector_id(agent))

    %{
      task_id: task.id,
      agent_id: agent.id,
      stage: :ask,
      folder: folder,
      prompt: ask_prompt(session, task, question),
      resume: session,
      fork: not is_nil(session)
    }
  end

  defp asked_conversation(task, connector_id) do
    case asked_role(task, connector_id) do
      :coder -> {task.code_session_id, task.worktree_path}
      :planner -> {task.plan_session_id, task.repository}
      nil -> {nil, task.worktree_path || task.repository}
    end
  end

  @doc """
  Whose conversation a question from `agent` (nil: none can answer) continues: the
  coder's, else the planner's, or nil. Only a conversation on the answerer's own bridge
  can be forked.
  """
  def asked_role(_task, nil), do: nil
  def asked_role(task, %{} = agent), do: asked_role(task, connector_id(agent))

  def asked_role(task, connector_id) do
    Enum.find([:coder, :planner], &conversation(&1, task, connector_id))
  end

  defp ask_prompt(nil, task, question), do: Prompts.ask(task, question)
  defp ask_prompt(_session, _task, question), do: Prompts.ask(question)

  ## Scheduler callbacks

  @doc """
  The scheduler picked the attempt up, before starting its run: the job starts, and a task
  still in todo moves to the job's working status (in progress, or review for a reviewer),
  so the board shows its agent took it. A question leaves the task alone. Returns the job.
  """
  def picked_up(%{job: %{stage: :ask} = job}), do: Scheduling.start_job!(job)

  def picked_up(%{job: %{task: task} = job}) do
    status = working_status(job.stage)

    {:ok, job} =
      Ash.transact([Board.Task, Notifications.Notification, Scheduling.Job], fn ->
        if task.status != status do
          apply_transition(task, %Transition{
            task: %{status: status, stage: job.stage},
            notifications: [notification(:started, "Agent started: #{task.title}")]
          })
        end

        Scheduling.start_job!(job)
      end)

    job
  end

  @doc "The attempt's run started."
  def run_started(attempt, run), do: Scheduling.mark_started!(attempt, run.id)

  @doc """
  The attempt's run finished: its result moves the task on. When the bridge can't be
  reached the attempt stays started, so the next sync tries again.
  """
  def run_done(attempt) do
    attempt =
      Ash.load!(attempt, [
        :agent_run,
        job: [task: [:attachment_names, assignee: :agent], agent: [connector_link: :connector]]
      ])

    %{job: job, agent_run: run} = attempt

    with {:ok, session} <- Connectors.session(job.agent.connector_link.connector, run.session_id) do
      case Result.parse(job.stage, session) do
        {:ok, result} ->
          transition = finished(job.stage, result, job, run)

          commit(job.task, fn ->
            budget_notes = record_usage(run, job, session.usage)
            Scheduling.mark_completed!(attempt)
            Transition.merge(transition, budget_notes)
          end)

          close(run)

        {:error, reason} ->
          run_failed(attempt, reason)
      end
    end
  end

  @doc "The attempt's run failed: a human takes over."
  def run_failed(attempt, reason) do
    attempt = Ash.load!(attempt, [:agent_run, job: [:task, agent: [connector_link: :connector]]])
    usage = failed_usage(attempt.job.agent, attempt.agent_run)

    commit(attempt.job.task, fn ->
      budget_notes = record_usage(attempt.agent_run, attempt.job, usage)
      Scheduling.mark_run_failed!(attempt, reason)
      Transition.merge(failure(attempt.job, reason), budget_notes)
    end)

    close(attempt.agent_run)
  end

  # A failed run spent tokens too. Its usage is read on a best-effort basis: the run may be
  # gone from the bridge, or its connector removed.
  defp failed_usage(%{connector_link: %{connector: connector}}, run) do
    case Connectors.session(connector, run.session_id) do
      {:ok, session} -> session.usage
      {:error, _unknown} -> nil
    end
  end

  defp failed_usage(_agent, _run), do: nil

  # A connector that reports no usage leaves no row. Returns the notes on the budgets the run
  # took past 80% or past their cap.
  defp record_usage(_run, _job, nil), do: %Transition{}

  defp record_usage(run, job, usage) do
    recorded =
      Agents.record_usage!(
        Map.merge(usage, %{agent_run_id: run.id, agent_id: run.agent_id, task_id: job.task_id})
      )

    job
    |> Budget.of()
    |> Enum.flat_map(&Budget.crossed(&1, recorded.cost_usd))
    |> budget_notes(job.task)
  end

  defp budget_notes(crossings, task) do
    %Transition{
      events:
        for {mark, _budget} <- crossings do
          %{kind: :budget, label: budget_title(mark), node_id: task.current_node_id}
        end,
      notifications:
        for {mark, budget} <- crossings do
          kind = if mark == :reached, do: :budget_reached, else: :budget_warning
          notification(kind, "#{budget_title(mark)}: #{task.title}", Budget.describe(budget))
        end
    }
  end

  defp budget_title(:warning), do: "Budget 80% spent"
  defp budget_title(:reached), do: "Budget reached"

  @doc """
  The attempt's run went silent or ran past its turn timeout. The run is stopped first, so
  a retry never works beside it; while the bridge can't stop it the attempt stays started
  and the next sync tries again. The job is retried like a failed start, and a human takes
  over once no retry is left.
  """
  def run_timed_out(attempt, timeout) do
    attempt = Ash.load!(attempt, [:agent_run, job: [:task, :agent]])
    %{job: job} = attempt
    reason = Timeout.reason(timeout)

    with {:ok, _run} <- Agents.stop_run(attempt.agent_run) do
      commit(job.task, fn ->
        Scheduling.mark_timed_out!(attempt, reason)
        event = timeout_event(job, timeout)

        case Scheduling.get_job!(job.id) do
          %{status: :failed} ->
            Transition.merge(failure(job, reason), %Transition{events: [event]})

          _retrying ->
            %Transition{
              events: [event],
              notifications: [
                notification(
                  :agent_stalled,
                  "Agent stalled: #{job.task.title}",
                  "#{reason} Retrying (attempt #{attempt.attempt + 1})."
                )
              ]
            }
        end
      end)
    end
  end

  defp timeout_event(job, %Timeout{kind: kind, minutes: minutes}) do
    what = if kind == :stalled, do: "stalled: silent for", else: "timed out after"

    %{
      kind: kind,
      label: "#{agent_label(job.agent.role)} #{what} #{minutes}m",
      node_id: job.node_id
    }
  end

  @doc """
  The run could not be started. A permanent failure hands the task to a human at once;
  a transient one is retried, and a human takes over once no retry is left.
  """
  def start_failed(attempt, %StartFailure{kind: :permanent, reason: reason}) do
    job = Ash.load!(attempt.job, [:task, :agent], reuse_values?: true)

    commit(job.task, fn ->
      Scheduling.mark_rejected!(attempt, reason)
      failure(job, "#{agent_label(job.agent.role)} can't start: #{reason}")
    end)
  end

  def start_failed(attempt, %StartFailure{kind: :transient, reason: reason}) do
    job = Ash.load!(attempt.job, [:task, :agent], reuse_values?: true)

    commit(job.task, fn ->
      Scheduling.mark_failed!(attempt, reason)

      case Scheduling.get_job!(job.id) do
        %{status: :failed} -> failure(job, "The agent could not be started: #{reason}")
        _retrying -> %Transition{}
      end
    end)
  end

  @doc "The job's agent is being removed: its run stops and a human takes the task over."
  def agent_removed(job, reason) do
    job = Ash.load!(job, [:task, :agent])

    commit(job.task, fn ->
      Scheduling.cancel_job!(job)
      failure(job, reason)
    end)
  end

  ## What a result does

  defp finished(:ask, answer, %{task: task, agent: agent}, _run) do
    %Transition{
      messages: [agent_message(agent.role, :reply, answer)],
      notifications: [notification(:answer_ready, "Answer ready: #{task.title}")]
    }
  end

  defp finished(stage, result, %{task: task} = job, run) do
    {own, outcome} = outcome(stage, result, job, run)
    task = merge(task, own.task)
    running = Workflows.running!(task)
    graph = running.graph

    case Graph.node(graph, task.current_node_id) do
      nil ->
        Transition.merge(
          own,
          stalled(task, nil, "The block this task was on was removed from its workflow.")
        )

      # Its version has problems with today's employees: the result stays, the task waits.
      _node when running.problems != [] ->
        Transition.merge(own, stalled(task, nil, Workflows.not_runnable(running)))

      node ->
        Transition.merge(own, next(task, graph, node, outcome, 0))
    end
  end

  defp outcome(:planning, plan, %{task: task, agent: agent}, run) do
    {%Transition{
       task: %{
         plan: plan,
         plan_session_id: run.claude_session_id,
         plan_session_connector_id: connector_id(agent),
         open_questions: plan.questions
       },
       messages: [agent_message(:planner, :plan, plan.summary)],
       notifications: [
         notification(:plan_ready, "Plan ready: #{task.title}", questions_note(plan.questions))
       ]
     }, if(plan.questions == [], do: :plan_ready, else: :needs_answers)}
  end

  defp outcome(:coding, %{status: :blocked} = result, %{task: task, agent: agent}, run) do
    {%Transition{
       task: %{
         code_session_id: run.claude_session_id,
         code_session_connector_id: connector_id(agent),
         outcome_summary: result.summary,
         open_questions: result.questions
       },
       messages: [agent_message(:coder, :outcome, result.summary)],
       notifications: [
         notification(
           :needs_answers,
           "Coder needs answers: #{task.title}",
           questions_note(result.questions)
         )
       ]
     }, :blocked}
  end

  # The reviewers collect the next round's findings afresh.
  defp outcome(:coding, %{status: :done} = result, %{agent: agent}, run) do
    {%Transition{
       task: %{
         code_session_id: run.claude_session_id,
         code_session_connector_id: connector_id(agent),
         outcome_summary: result.summary,
         open_questions: [],
         findings: []
       },
       messages: [agent_message(:coder, :outcome, result.summary)]
     }, :done}
  end

  # A reviewer's outcome counts the round's findings so far, its own and earlier reviewers'.
  # Its block running again in the round (a loop) reviewed the same code: its new findings
  # replace the ones it found before.
  defp outcome(stage, review, %{task: task, agent: agent}, _run)
       when stage in [:code_review, :qa] do
    block = task.current_node_id
    found = Enum.map(review.findings, &%{&1 | block_id: block})
    findings = Enum.reject(task.findings, &(&1.block_id == block)) ++ found

    {%Transition{
       task: %{findings: findings},
       messages: [agent_message(agent.role, :findings, review.summary)]
     }, review_outcome(findings)}
  end

  defp outcome(nil, summary, %{agent: agent}, _run) do
    {%Transition{
       task: %{outcome_summary: summary},
       messages: [agent_message(agent.role, :outcome, summary)]
     }, :done}
  end

  defp review_outcome([]), do: :clean
  defp review_outcome(_findings), do: :findings

  ## Walking the graph

  # How a block is entered: through `edge` (a self-loop when `loop?`), again to continue the
  # same run (`again?`: answers, comments), started by a human (`queued?`, `strict?` for
  # Continue), with the `prompt` a resumed conversation gets, and the human `decision`
  # (`%{label, comment}`) that sent it there, which an agent starting afresh is told.
  defp arrival(fields) do
    Map.merge(
      %{
        edge: nil,
        loop?: false,
        again?: false,
        queued?: false,
        strict?: false,
        prompt: nil,
        decision: nil
      },
      Map.new(fields)
    )
  end

  # Where an outcome of `node` leads. An entry the graph can't make (an agent that can't
  # run, no worktree…) leaves the task with a human on the block it was entering (inside
  # a group: the group's first block, which Continue then runs).
  defp next(task, graph, node, outcome, hops) do
    case Graph.route(graph, node.id, outcome, counts(task)) do
      {:follow, edge} ->
        task = traverse(task, edge)
        arrival = arrival(edge: edge, loop?: edge.from_node_id == edge.to_node_id)

        case enter(task, graph, edge.to_node_id, arrival, hops + 1) do
          {:ok, transition} ->
            transition

          {:error, error} ->
            {target, _groups} = Graph.resolve(graph, edge.to_node_id)
            stalled(task, target.id, ErrorText.readable(error))
        end

      :pause ->
        %Transition{task: %{status: :await_human_supervision}}

      :none ->
        stalled(task, node.id, "#{node.label} has no arrow for #{outcome_label(outcome)}.")
    end
  end

  defp outcome_label(nil), do: "going on"
  defp outcome_label(outcome), do: "“#{outcome}”"

  defp counts(task), do: %{edges: task.edge_counts, nodes: task.node_counts}

  defp traverse(task, edge),
    do: merge(task, %{edge_counts: Map.update(task.edge_counts, edge.id, 1, &(&1 + 1))})

  defp enter(_task, _graph, _id, _arrival, hops) when hops > @max_hops do
    {:error,
     Refused.exception(
       reason: "The workflow goes round without reaching a block that does anything."
     )}
  end

  defp enter(task, graph, id, arrival, hops) do
    {node, groups} = Graph.resolve(graph, id)
    entered = groups_entered(graph, id, arrival) ++ Enum.map(groups, & &1.id) ++ [node.id]
    node_counts = Enum.reduce(entered, task.node_counts, &count_run(&1, &2, arrival))
    task = merge(task, %{current_node_id: node.id, node_counts: node_counts})
    arrive(node, task, graph, arrival, hops)
  end

  # An arrow from outside a group into a block inside it enters the group too, as does a
  # human starting a block inside one: its self-loop counts runs afresh.
  defp groups_entered(graph, id, %{edge: nil}), do: Graph.groups_around(graph, id)

  defp groups_entered(graph, id, %{edge: edge}),
    do: Graph.groups_around(graph, id) -- Graph.groups_around(graph, edge.from_node_id)

  defp count_run(id, counts, %{again?: true}), do: Map.put_new(counts, id, 1)

  # Looping, it ran once already even without a count (Graph.route/4: a group a human
  # started on one of its blocks directly).
  defp count_run(id, counts, %{loop?: true, edge: %{to_node_id: id}}),
    do: Map.update(counts, id, 2, &(&1 + 1))

  defp count_run(id, counts, _arrival), do: Map.put(counts, id, 1)

  # The version goes with the place: a task entering its workflow afresh pins the latest.
  defp place(task) do
    Map.take(task, [:current_node_id, :workflow_version, :node_counts, :edge_counts])
  end

  defp arrive(%{kind: :agent} = node, task, graph, arrival, hops) do
    case Graph.role(graph, node.id) do
      nil ->
        {:error,
         Refused.exception(
           reason: "#{node.label} names no agent any more. Pick one in the workflow."
         )}

      role ->
        run_agent(node, role, task, graph, arrival, hops)
    end
  end

  # A plan waiting for approval keeps its stage, so the plan view stays open.
  defp arrive(%{kind: :human} = node, task, _graph, _arrival, _hops) do
    stage = if task.stage == :planning, do: :planning, else: nil

    {:ok,
     %Transition{
       task:
         task
         |> place()
         |> Map.merge(%{
           status: :await_human_supervision,
           stage: stage,
           assignee_id: node.employee_id
         }),
       notifications: human_notifications(task, node)
     }}
  end

  defp arrive(%{kind: :column, column_status: status}, task, _graph, _arrival, _hops)
       when status in [:done, :canceled] do
    {:ok,
     %Transition{
       task: task |> place() |> Map.merge(%{status: status, stage: nil, current_node_id: nil})
     }}
  end

  # Any other column passes the task on along its arrow, or keeps it there without one.
  defp arrive(%{kind: :column} = node, task, graph, _arrival, hops) do
    task = merge(task, %{status: node.column_status})
    here = %Transition{task: Map.put(place(task), :status, node.column_status)}

    case Graph.route(graph, node.id, nil, counts(task)) do
      {:follow, _edge} -> {:ok, Transition.merge(here, next(task, graph, node, nil, hops))}
      _rest -> {:ok, here}
    end
  end

  # Runs nothing: the worst severity among the round's open findings picks the arrow.
  defp arrive(%{kind: :triage} = node, task, graph, _arrival, hops) do
    here = %Transition{task: place(task)}
    {:ok, Transition.merge(here, next(task, graph, node, Graph.triage(task.findings), hops))}
  end

  defp human_notifications(%{stage: :planning}, _node), do: []

  defp human_notifications(%{stage: stage} = task, _node) when stage in [:code_review, :qa] do
    body =
      case task.findings do
        [] ->
          "Both reviewers found nothing."

        findings ->
          "#{length(findings)} findings are still open after #{task.review_round} fix rounds."
      end

    [notification(:ready_to_merge, "Ready to merge: #{task.title}", body)]
  end

  defp human_notifications(task, node),
    do: [
      notification(
        :decision_needed,
        "#{node.label}: #{task.title}",
        "The task waits for your decision."
      )
    ]

  defp run_agent(node, role, task, graph, arrival, hops) do
    case pick(node, role, task, arrival) do
      {:ok, agent} -> queue(node, role, agent, task, graph, arrival)
      :skip -> {:ok, skip(node, role, task, graph, hops)}
      {:error, error} -> {:error, error}
    end
  end

  # A reviewer block with no agent that can run is skipped, as if it found nothing new.
  defp skip(node, role, task, graph, hops) do
    {stage, agent} =
      if role == :reviewer,
        do: {"code review", "reviewer"},
        else: {"docker review", "docker reviewer"}

    task = merge(task, %{stage: stage(role)})

    Transition.merge(
      %Transition{
        task: Map.put(place(task), :stage, task.stage),
        notifications: [
          notification(
            :stage_skipped,
            "Skipped #{stage}: #{task.title}",
            "No #{agent} agent with a model and a connector is set up."
          )
        ]
      },
      next(task, graph, node, review_outcome(task.findings), hops)
    )
  end

  defp queue(node, role, agent, task, graph, arrival) do
    stage = stage(role)

    with {:ok, worktree} <- worktree(role, agent, task) do
      task = merge(task, worktree)
      fix? = role == :coder and fix?(task, arrival)
      task = if fix?, do: merge(task, %{review_round: task.review_round + 1}), else: task
      {prompt, resume} = prompt(node, role, task, graph, agent, arrival, fix?)

      attrs =
        task
        |> place()
        |> Map.merge(worktree)
        |> Map.merge(%{
          stage: stage,
          status: if(arrival.queued?, do: queued_status(stage), else: working_status(stage)),
          open_questions: [],
          review_round: task.review_round
        })
        |> Map.put(:assignee_id, agent.employee.id)

      job = %{
        task_id: task.id,
        agent_id: agent.id,
        node_id: node.id,
        stage: stage,
        folder: folder(role, task),
        prompt: prompt,
        json_schema: Prompts.schema(stage),
        resume: resume
      }

      # A block's own timeouts; where it has none the job's defaults apply.
      limits =
        node
        |> Map.take([:stall_timeout_minutes, :turn_timeout_minutes])
        |> Map.reject(fn {_limit, minutes} -> is_nil(minutes) end)

      job = Map.merge(job, limits)

      {:ok, %Transition{task: attrs, jobs: [job]}}
    end
  end

  # Coming back from the reviewers with their findings (not sent by a human's own words).
  defp fix?(task, arrival),
    do: task.findings != [] and arrival.edge != nil and is_nil(arrival.prompt)

  defp worktree(:coder, agent, %{worktree_path: nil} = task) do
    case Connectors.create_worktree(
           agent.connector_link.connector,
           task.repository,
           short_id(task)
         ) do
      {:ok, worktree} ->
        {:ok,
         %{
           worktree_path: worktree.path,
           worktree_branch: worktree.branch,
           review_round: 0,
           findings: []
         }}

      {:error, message} ->
        {:error, WorktreeRefused.exception(reason: message)}
    end
  end

  defp worktree(role, _agent, %{worktree_path: nil}) when role in @review_roles,
    do: {:error, NoWorktree.exception(target: :review)}

  defp worktree(_role, _agent, _task), do: {:ok, %{}}

  # A block that ran before continues its conversation (planner, coder: one per role per
  # task, so a second block in the role knows what the first did, unless its agent is on
  # another connector, whose bridge can't resume it); reviewers and custom agents start
  # afresh every time. The block's own instructions come along either way.
  defp prompt(node, role, task, graph, agent, arrival, fix?) do
    case {conversation(role, task, connector_id(agent)), arrival.prompt} do
      {nil, _prompt} when fix? ->
        fix = Prompts.fix(task.findings, task.review_round, fix_round_limit(graph))
        {Prompts.followed_by(first_prompt(role, task, agent, node.prompt), fix), nil}

      {nil, _prompt} ->
        {decided(first_prompt(role, task, agent, node.prompt), arrival.decision), nil}

      {session, nil} when fix? ->
        fix = Prompts.fix(task.findings, task.review_round, fix_round_limit(graph))
        {Prompts.for_step(fix, node.prompt), session}

      # An arrow from another block (a second block in the role, a self-loop): no human asked.
      {session, nil} when not arrival.queued? ->
        {Prompts.for_step(Prompts.again(graph.nodes[task.current_node_id].label), node.prompt),
         session}

      {session, nil} ->
        {Prompts.for_step(Prompts.carry_on(), node.prompt), session}

      {session, prompt} ->
        {Prompts.for_step(prompt, node.prompt), session}
    end
  end

  defp decided(prompt, nil), do: prompt
  defp decided(prompt, decision), do: Prompts.decided(prompt, decision.label, decision.comment)

  defp conversation(:planner, task, connector_id),
    do: if(task.plan_session_connector_id in [nil, connector_id], do: task.plan_session_id)

  defp conversation(:coder, task, connector_id),
    do: if(task.code_session_connector_id in [nil, connector_id], do: task.code_session_id)

  defp conversation(_role, _task, _connector_id), do: nil

  defp connector_id(agent), do: agent.connector_link.connector_id

  defp first_prompt(:planner, task, _agent, step), do: Prompts.plan(task, step)
  defp first_prompt(:coder, task, _agent, step), do: Prompts.code(task, step)

  defp first_prompt(:reviewer, task, agent, step),
    do: Prompts.review(task, diff(agent, task), step)

  defp first_prompt(:qa, task, _agent, step), do: Prompts.qa(task, step)
  defp first_prompt(:custom, task, _agent, step), do: Prompts.task(task, step)

  defp folder(role, task) when role in [:planner, :custom], do: task.repository
  defp folder(_role, task), do: task.worktree_path

  defp diff(agent, task) do
    case Connectors.worktree_diff(agent.connector_link.connector, task.worktree_path) do
      {:ok, diff} -> diff
      {:error, message} -> "(The diff could not be loaded: #{message})"
    end
  end

  # Which agent runs a block: the one it names; for a role, the first that can run, or for
  # a coder role the one pinned when the plan was approved (which then must be able to
  # run). A role nobody has yet gets its default agent while a connector is connected
  # (`Organization.DefaultAgent`); when it can't be made there, the block is refused, a
  # reviewer one too. A reviewer role with none that can run is skipped, unless a human
  # asked for it by Continue while its agents only lack setup. A refusal names the block.
  defp pick(%{employee_id: nil} = node, role, task, arrival) do
    case agents_or_default(role) do
      {:ok, agents} ->
        pick_in(agents, node, role, task, arrival)

      {:error, reason} ->
        {:error, NoAgent.exception(role: role, block: node.label, default_error: reason)}
    end
  end

  defp pick(node, role, _task, _arrival) do
    employee =
      Organization.get_employee!(node.employee_id,
        load: [agent: [:employee, connector_link: :connector]]
      )

    if runnable?(employee.agent),
      do: {:ok, employee.agent},
      else: {:error, not_runnable(node, role, [employee.agent])}
  end

  defp agents_or_default(role), do: agents_or_default(role, agents_in(role))

  defp agents_or_default(role, []) do
    case DefaultAgent.provision(role) do
      {:ok, agent} -> {:ok, [agent]}
      :none -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp agents_or_default(_role, agents), do: {:ok, agents}

  defp pick_in(agents, node, role, task, arrival) do
    pinned = role == :coder && Enum.find(agents, &(&1.employee.id == task.pinned_coder_id))
    runnable = Enum.find(agents, &runnable?/1)

    cond do
      pinned ->
        if runnable?(pinned),
          do: {:ok, pinned},
          else: {:error, not_runnable(node, role, [pinned])}

      runnable ->
        {:ok, runnable}

      role in @review_roles and not (arrival.strict? and agents != []) ->
        :skip

      true ->
        {:error, not_runnable(node, role, agents)}
    end
  end

  defp runnable?(agent), do: is_nil(Agents.missing_setup(agent))

  defp agents_in(role) do
    Agents.list_agents!(
      query: [filter: [role: role], sort: [id: :asc]],
      load: [:employee, connector_link: :connector]
    )
  end

  defp not_runnable(node, role, []), do: NoAgent.exception(role: role, block: node.label)

  defp not_runnable(node, _role, [agent | _]),
    do:
      NotRunnable.exception(
        name: agent.employee.name,
        missing: Agents.missing_setup(agent),
        block: node.label
      )

  # The task waits for a human on `id` (the block it is on when nil): something in the
  # graph or its agents keeps it from going on, and the message says what.
  defp stalled(task, id, reason) do
    place =
      case id do
        nil -> %{}
        id -> %{current_node_id: id}
      end

    %Transition{
      task:
        Map.merge(
          %{
            status: :await_human_supervision,
            workflow_version: task.workflow_version,
            edge_counts: task.edge_counts,
            node_counts: task.node_counts
          },
          place
        ),
      messages: [%{author: :agent, kind: :system, body: reason}],
      notifications: [notification(:workflow_stuck, "Stuck: #{task.title}", reason)]
    }
  end

  ## Human steps (Board.Task.Changes.Transition)

  @doc """
  A move to todo runs the workflow: the task's current block again (its agent carries
  on), or the start block when it has none or is parked on a column block with no arrow
  on, with fix rounds and counts afresh (an ended task starts over). A task whose agent
  still works on it keeps that job.
  """
  def start(task, _arguments) do
    if Scheduling.active_jobs!(task.id) == [] do
      {task, graph} = prepare(task)

      case {resumable(graph, task), graph.start_id} do
        {nil, nil} ->
          {:error, Refused.exception(reason: "This task's workflow has no start block yet.")}

        {nil, start} ->
          afresh(task, graph, Graph.node(graph, start), arrival(queued?: true))

        {node, _start} ->
          enter(task, graph, node.id, arrival(queued?: true), 0)
      end
    else
      {:ok, %Transition{}}
    end
  end

  # Entering a column block again would only move the task back there: one the workflow
  # ends on is where it stopped, not where it goes on.
  defp resumable(graph, task) do
    case Graph.node(graph, task.current_node_id) do
      %{kind: :column} = node ->
        if match?({:follow, _edge}, Graph.route(graph, node.id, nil, counts(task))), do: node

      node ->
        node
    end
  end

  @doc """
  A move into review runs the workflow from its first reviewer block, with fix rounds and
  traversal counts afresh. A task whose reviewer already works on it keeps it.
  """
  def review(task, _arguments) do
    if Enum.any?(Scheduling.active_jobs!(task.id), &(&1.stage in [:code_review, :qa])) do
      {:ok, %Transition{}}
    else
      {task, graph} = prepare(task)

      case first_reviewer(graph) do
        nil -> {:error, Refused.exception(reason: "This task's workflow has no reviewer block.")}
        node -> afresh(task, graph, node, arrival(queued?: true))
      end
    end
  end

  defp first_reviewer(graph),
    do: Enum.find(Graph.order(graph), &(Graph.role(graph, &1.id) in @review_roles))

  defp afresh(task, graph, node, arrival) do
    fresh = %{review_round: 0, findings: [], edge_counts: %{}, node_counts: %{}}

    with {:ok, transition} <- enter(merge(task, fresh), graph, node.id, arrival, 0) do
      {:ok, Transition.merge(%Transition{task: fresh}, transition)}
    end
  end

  @doc "A comment on the plan resumes the planner that wrote it."
  def comment(task, %{body: body, step_ids: step_ids}) do
    message = %{author: :human, kind: :comment, body: body, step_ids: step_ids}
    event = human_event(task, :comment, "Commented on the plan")
    reply(task, Prompts.revise_plan(body, step_ids), message, event)
  end

  @doc "Answers resume the planner or coder that asked."
  def answer(task, %{answers: answers}) do
    questions = task.open_questions
    message = %{author: :human, kind: :answer, body: Prompts.answered(questions, answers)}
    event = human_event(task, :answer, answered_label(questions))
    reply(task, Prompts.answers(task.stage, questions, answers), message, event)
  end

  defp answered_label([_]), do: "Answered a question"
  defp answered_label(questions), do: "Answered #{length(questions)} questions"

  # Back to the block whose result the human answers, without taking an arrow.
  defp reply(task, prompt, message, event) do
    {task, graph} = prepare(task)
    role = if task.stage == :planning, do: :planner, else: :coder

    case asking_node(graph, task, role) do
      nil ->
        {:error,
         Refused.exception(reason: "This task's workflow has no #{Role.label(role)} block.")}

      node ->
        with {:ok, transition} <-
               enter(task, graph, node.id, arrival(again?: true, prompt: prompt), 0) do
          {:ok, Transition.merge(%Transition{messages: [message], events: [event]}, transition)}
        end
    end
  end

  # The block on, when it has the role; else one in the role with an arrow into it, else
  # the first in the role.
  defp asking_node(graph, task, role) do
    in_role? = &(Graph.role(graph, &1.id) == role)
    current = Graph.node(graph, task.current_node_id)

    sources =
      for edge <- graph.edges,
          edge.to_node_id == task.current_node_id,
          do: Graph.node(graph, edge.from_node_id)

    Enum.find(List.wrap(current) ++ sources ++ Graph.order(graph), in_role?)
  end

  @doc """
  "Ready for development": takes the approval arrow from the plan's human block to its
  coder block (`approval/2`). A `coder_employee_id` pins that coder for the task's coder
  role blocks; without one they run the first coder that can.
  """
  def approve(task, arguments) do
    coder_id = arguments[:coder_employee_id]

    {task, graph} = prepare(task)

    case approval_path(graph, task) do
      [] ->
        {:error,
         Refused.exception(reason: "This task's workflow has no arrow from the plan to a coder.")}

      edges ->
        approved = %{
          pinned_coder_id: coder_id,
          plan_approved_at: DateTime.utc_now(),
          open_questions: []
        }

        task = edges |> Enum.reduce(task, &traverse(&2, &1)) |> merge(approved)
        edge = List.last(edges)

        with {:ok, transition} <-
               enter(task, graph, edge.to_node_id, arrival(edge: edge, queued?: true), 0) do
          event = human_event(task, :approve, "Approved the plan")
          {:ok, Transition.merge(%Transition{task: approved, events: [event]}, transition)}
        end
    end
  end

  @doc """
  The coder block the task's plan approval leads to, or nil: from the plan's human block
  its arrow to a coder block (the one named `approved` first), or from a planner waiting
  for answers its `plan_ready` arrow on to that.
  """
  def approval(task, graph) do
    case approval_path(graph, task) do
      [] -> nil
      edges -> edges |> List.last() |> then(&Graph.resolve(graph, &1.to_node_id)) |> elem(0)
    end
  end

  defp approval_path(graph, task) do
    current = Graph.node(graph, task.current_node_id)

    cond do
      is_nil(current) ->
        []

      current.kind == :human ->
        List.wrap(approval_arrow(graph, current))

      Graph.role(graph, current.id) == :planner ->
        case Graph.route(graph, current.id, :plan_ready, counts(task)) do
          {:follow, edge} -> through(graph, edge)
          _none -> []
        end

      true ->
        []
    end
  end

  defp through(graph, edge) do
    {target, _groups} = Graph.resolve(graph, edge.to_node_id)

    cond do
      Graph.role(graph, target.id) == :coder ->
        [edge]

      target.kind == :human ->
        if arrow = approval_arrow(graph, target), do: [edge, arrow], else: []

      true ->
        []
    end
  end

  defp approval_arrow(graph, human) do
    graph
    |> Graph.outgoing(human.id)
    |> Enum.filter(&(target_role(graph, &1) == :coder))
    |> Enum.sort_by(&(&1.condition != "approved"))
    |> List.first()
  end

  @doc """
  The decisions a human can take on the task now: the arrows out of the human block it
  waits on that their cap still allows, each with the block it leads to.
  """
  def decisions(task, graph) do
    case Graph.node(graph, task.current_node_id) do
      %{kind: :human} = node when task.status == :await_human_supervision ->
        for edge <- Graph.outgoing(graph, node.id),
            open?(edge, task),
            do: %{edge: edge, target: graph.nodes[edge.to_node_id]}

      _other ->
        []
    end
  end

  # A self-loop's cap counts the block's runs in a row, any other arrow's its traversals.
  defp open?(%{from_node_id: id, to_node_id: id} = loop, task),
    do: Map.get(task.node_counts, id, 0) < loop.iterations

  defp open?(edge, task), do: not Graph.exhausted?(edge, task.edge_counts)

  @doc "A human takes one of the arrows out of the human block the task waits on."
  def decide(task, %{edge_id: edge_id} = arguments) do
    {task, graph} = prepare(task)

    case Enum.find(decisions(task, graph), &(&1.edge.id == edge_id)) do
      nil ->
        {:error, Refused.exception(reason: "That decision is not open on this task any more.")}

      %{edge: edge} ->
        comment = arguments[:comment]
        message = %{author: :human, kind: :decision, body: decision_note(edge.condition, comment)}
        decided = edge.condition || Graph.node(graph, edge.to_node_id).label
        event = human_event(task, :decide, "Decided: #{decided}")

        arrival =
          arrival(
            edge: edge,
            loop?: edge.from_node_id == edge.to_node_id,
            queued?: true,
            prompt: Prompts.decision(edge.condition, comment, task.findings),
            decision: %{label: edge.condition, comment: comment}
          )

        with {:ok, transition} <- enter(traverse(task, edge), graph, edge.to_node_id, arrival, 0) do
          {:ok, Transition.merge(%Transition{messages: [message], events: [event]}, transition)}
        end
    end
  end

  defp decision_note(label, nil), do: "Decided: #{label}"
  defp decision_note(label, comment), do: "Decided: #{label}\n\n#{comment}"

  ## Continue

  @doc """
  Whether the task's newest workflow job failed (the task waits for a human, or still sits
  in todo / in progress / review), or its start waits for a retry.
  """
  def restartable?(task) do
    case Scheduling.latest_job!(task.id) do
      %{status: :failed} ->
        task.status in [:await_human_supervision, :todo, :in_progress, :review]

      %{status: :on_start, scheduled_jobs: attempts} ->
        task.status in [:todo, :in_progress, :review] and
          Enum.any?(attempts, &(&1.state == :failed))

      _none_or_fine ->
        false
    end
  end

  @doc """
  Where Continue can take the task, the default first: a block of its workflow (agent
  and human blocks, reviewers only once there is code) by id, or "done". The default is
  the agent block it is on (also after a failure), else its first reviewer once it has
  code, else its start block.
  """
  def continue_targets(task) do
    graph = Workflows.running!(task).graph

    blocks =
      for node <- Graph.order(graph),
          node.kind in [:agent, :human],
          task.worktree_path || Graph.role(graph, node.id) not in @review_roles,
          do: %{id: node.id, label: node.label}

    done = if task.status == :done, do: [], else: [%{id: "done", label: "Mark done"}]
    targets = blocks ++ done
    default = Enum.find(targets, &(&1.id == default_target(task, graph))) || List.first(targets)
    [default | List.delete(targets, default)]
  end

  defp default_target(task, graph) do
    current = Graph.node(graph, task.current_node_id)
    reviewer = task.worktree_path && first_reviewer(graph)

    cond do
      current && current.kind == :agent -> current.id
      reviewer -> reviewer.id
      true -> graph.start_id
    end
  end

  @doc """
  What Continue to `target` does, whatever the task is stuck in (the caller cancels its
  active jobs first): the block is entered again (planner and coder carry on in their
  conversation with a "carry on" prompt, or start fresh without one; a reviewer block
  starts the review over with fix rounds afresh), or "done" is a move. Each comes with a
  "Continued by you" message. `{:error, exception}` names what is missing: an agent that
  can't run, no agent in the role, or no worktree.
  """
  def continue(task, %{target: target}) do
    {task, graph} = prepare(task)
    target = target || default_target(task, graph)

    with {:ok, label, transition} <- continue_to(target, task, graph) do
      message = %{author: :human, kind: :restart, body: "Continued by you → #{label}"}
      event = human_event(task, :continue, "Continued → #{label}")
      {:ok, Transition.merge(%Transition{messages: [message], events: [event]}, transition)}
    end
  end

  defp continue_to("done", _task, _graph),
    do: {:ok, "done", %Transition{task: %{status: :done, current_node_id: nil}}}

  defp continue_to(id, task, graph) do
    arrival = arrival(queued?: true, strict?: true, prompt: Prompts.carry_on())

    with %{} = node <- Graph.node(graph, id),
         {:ok, transition} <- continue_into(node, task, graph, arrival) do
      {:ok, node.label, transition}
    else
      nil ->
        {:error, Refused.exception(reason: "That block is no longer in this task's workflow.")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp continue_into(node, task, graph, arrival) do
    if Graph.role(graph, node.id) in @review_roles,
      do: afresh(task, graph, node, arrival),
      else: enter(task, graph, node.id, arrival, 0)
  end

  @doc "Creates the transition's messages, notifications, jobs and events for `task`."
  def record(task, transition) do
    Enum.each(transition.messages, &Board.create_message!(Map.put(&1, :task_id, task.id)))
    Enum.each(transition.notifications, &Notifications.notify!(Map.put(&1, :task_id, task.id)))
    Enum.each(transition.jobs, &Scheduling.create_job!/1)
    Enum.each(transition.events, &Board.record_event!(Map.put(&1, :task_id, task.id)))
  end

  # The task with the version its step runs on (`Workflows.running_version/2`), and its graph.
  defp prepare(task) do
    task = Ash.load!(task, [:attachment_names, assignee: :agent], reuse_values?: true)
    running = Workflows.running!(task)
    {merge(task, %{workflow_version: running.version}), running.graph}
  end

  defp merge(task, attrs), do: Map.merge(task, attrs)

  ## Failures

  # A question that can't be answered says so; the task's own work goes on untouched.
  defp failure(%{stage: :ask} = job, reason) do
    %Transition{
      messages: [
        %{
          author: :agent,
          agent_role: job.agent.role,
          kind: :unanswered,
          body: "Your question could not be answered: #{reason}"
        }
      ],
      notifications: [notification(:agent_failed, "Question failed: #{job.task.title}", reason)]
    }
  end

  defp failure(job, reason) do
    %Transition{
      task: %{status: :await_human_supervision},
      messages: [%{author: :agent, agent_role: job.agent.role, kind: :system, body: reason}],
      notifications: [notification(:agent_failed, "Agent failed: #{job.task.title}", reason)]
    }
  end

  defp agent_label(role), do: "The #{String.downcase(Role.label(role))}"

  defp agent_message(role, kind, body) do
    %{author: :agent, agent_role: role, kind: kind, body: body}
  end

  defp notification(kind, title, body \\ nil), do: %{kind: kind, title: title, body: body}

  # A human step for the task's audit timeline, on the block the task was on.
  defp human_event(task, kind, label),
    do: %{kind: kind, label: label, node_id: task.current_node_id}

  defp questions_note([]), do: nil
  defp questions_note([_]), do: "1 question waits for an answer."
  defp questions_note(questions), do: "#{length(questions)} questions wait for an answer."

  ## Applying

  defp commit(task, step) do
    {:ok, task} =
      Ash.transact(
        [
          Board.Task,
          Board.TaskMessage,
          Board.TaskEvent,
          Notifications.Notification,
          Scheduling.Job
        ],
        fn -> apply_transition(task, step.()) end
      )

    task
  end

  defp apply_transition(task, transition) do
    task = if transition.task == %{}, do: task, else: Board.advance_task!(task, transition.task)
    record(task, transition)
    task
  end

  # Only hides the run from the dashboard, so a bridge that can't be reached is fine.
  defp close(run), do: Agents.stop_run(run)
end
