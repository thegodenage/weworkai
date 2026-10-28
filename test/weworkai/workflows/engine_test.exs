defmodule Weworkai.Workflows.EngineTest do
  use Weworkai.DataCase, async: false

  # Start failures are logged with their full detail.
  @moduletag :capture_log

  import ExUnit.CaptureLog

  require Ash.Query

  alias Weworkai.{Agents, Board, BridgeStub, Connectors, Notifications, Organization, Workflows}
  alias Weworkai.{ErrorText, Scheduling}
  alias Weworkai.Scheduling.{Job, Scheduler}

  import Weworkai.WorkflowFixtures
  alias Weworkai.Workflows.{Engine, Prompts}

  setup do
    connector = Connectors.create_connector!(%{name: "Claude", provider: :claude_code})
    %{bridge: BridgeStub.start(), connector: connector}
  end

  defp agent(connector, name, role) do
    employee =
      Organization.create_employee!(%{
        kind: :agent,
        name: name,
        agent_role: role,
        connector_id: connector.id
      })

    # Skips :configure, whose check would ask the bridge for its model list.
    employee.agent_id
    |> Agents.get_agent!()
    |> Ash.Changeset.for_update(:assign_role, %{role: role})
    |> Ash.Changeset.force_change_attributes(%{model: "claude-opus-5-5"})
    |> Ash.update!()

    employee
  end

  defp with_status(connector, status) do
    connector
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:status, status)
    |> Ash.update!()
  end

  defp team(connector, roles) do
    Map.new(roles, &{&1, agent(connector, "#{&1}", &1)})
  end

  defp planned_task(%{bridge: bridge, connector: connector}, roles \\ [:reviewer, :qa]) do
    team = team(connector, [:planner, :coder | roles])

    task =
      Board.create_task!(%{
        title: "Greet users",
        description: "Say hello",
        repository: "/repos/app"
      })

    Board.move_task!(task, :todo)
    BridgeStub.step(bridge)
    {Board.get_task!(task.id), team}
  end

  defp started_runs do
    Stream.repeatedly(fn ->
      receive do
        {:bridge, "POST", "/sessions", body} -> body
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  defp flush_bridge do
    receive do
      {:bridge, _method, _path, _body} -> flush_bridge()
    after
      0 -> :ok
    end
  end

  defp notification_kinds, do: Enum.map(Notifications.recent_notifications!(), & &1.kind)

  defp jobs(task) do
    Job
    |> Ash.Query.filter(task_id == ^task.id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
  end

  describe "planning" do
    test "todo starts the planner; its plan waits for a human", context do
      Phoenix.PubSub.subscribe(Weworkai.PubSub, "notifications")
      Phoenix.PubSub.subscribe(Weworkai.PubSub, "tasks")
      {task, team} = planned_task(context)

      assert_received {:notification_created, %{kind: :started}}
      assert_received {:notification_created, %{kind: :plan_ready}}
      assert_received {:task_updated, %{status: :await_human_supervision}}

      assert [%{"profile" => "planner", "cwd" => "/repos/app", "resume" => nil} = run] =
               started_runs()

      assert run["prompt"] =~ "Greet users"
      assert run["prompt"] =~ "writes are blocked"
      assert run["jsonSchema"]["required"] == ["summary", "steps", "questions"]

      assert task.status == :await_human_supervision
      assert task.stage == :planning
      assert [%{id: "s1", changes: [%{path: "lib/greeting.ex"}]}, %{id: "s2"}] = task.plan.steps
      assert [%{id: "q1", options: ["No", "Gettext"]}] = task.open_questions
      assert task.plan_session_id
      assert [%{agent_id: agent_id, stage: :planning}] = jobs(task)
      assert agent_id == team.planner.agent_id

      assert [%{author: :agent, agent_role: :planner, kind: :plan}] =
               Board.list_messages!(task.id)

      assert notification_kinds() == [:plan_ready, :started]
      assert Notifications.unread_notification_count!() == 2
      Notifications.mark_notification_read!(hd(Notifications.recent_notifications!()))
      assert Notifications.unread_notification_count!() == 1
      Notifications.mark_all_notifications_read!()
      assert Notifications.unread_notification_count!() == 0
      assert Agents.active_runs!() == []
    end

    test "a comment resumes the planner, which revises the plan", %{bridge: bridge} = context do
      {task, _team} = planned_task(context)
      flush_bridge()

      task = Board.comment_on_plan!(task, "Use gettext", ["s2"])
      assert task.status == :in_progress
      BridgeStub.step(bridge)

      assert [%{"profile" => "planner", "resume" => resume, "prompt" => prompt}] = started_runs()
      assert resume == task.plan_session_id
      assert prompt =~ "[step s2] Use gettext"

      task = Board.get_task!(task.id)
      assert task.status == :await_human_supervision
      assert task.open_questions == []
      assert task.plan.summary == "Add a greeting helper."

      assert [%{kind: :plan}, %{kind: :comment, step_ids: ["s2"]}, %{kind: :plan}] =
               Board.list_messages!(task.id)
    end

    test "answering the planner's questions resumes it", %{bridge: bridge} = context do
      {task, _team} = planned_task(context)
      flush_bridge()

      Board.answer_questions!(task, %{"q1" => "Gettext"})
      BridgeStub.step(bridge)

      assert [%{"profile" => "planner", "prompt" => prompt}] = started_runs()
      assert prompt =~ "Localize the greeting?"
      assert prompt =~ "→ Gettext"
      assert [_plan, %{kind: :answer, author: :human}, _revised] = Board.list_messages!(task.id)
    end
  end

  describe "coding and review" do
    test "approval runs the coder in a worktree, then both reviewers in review, then it is ready to merge",
         %{bridge: bridge} = context do
      {task, team} = planned_task(context)
      flush_bridge()

      task = Board.approve_plan!(task, team.coder.id)

      assert_received {:bridge, "POST", "/worktrees", %{"repo" => "/repos/app", "name" => name}}
      assert name == String.slice(task.id, 0, 8)
      assert task.status == :todo
      assert task.assignee_id == team.coder.id
      assert task.plan_approved_at
      assert task.worktree_path == "/repos/app/.weworkai/worktrees/#{name}"
      assert task.worktree_branch == "weworkai/#{name}"

      BridgeStub.step(bridge)
      assert [%{"profile" => "coder", "cwd" => cwd, "prompt" => prompt}] = started_runs()
      assert cwd == task.worktree_path
      assert prompt =~ "+defmodule Greeting"
      assert prompt =~ "subagents"
      assert prompt =~ "Commit your work on branch `weworkai/#{name}`"

      task = Board.get_task!(task.id)
      assert %{status: :review, stage: :code_review} = task
      assert task.code_session_id
      # Whoever runs the block the task is on is its assignee.
      assert task.assignee_id == team.reviewer.id

      BridgeStub.step(bridge)
      assert [%{"profile" => "reviewer", "prompt" => prompt}] = started_runs()
      assert prompt =~ BridgeStub.diff()
      assert %{status: :review, stage: :qa} = Board.get_task!(task.id)

      BridgeStub.step(bridge)
      assert [%{"profile" => "qa", "prompt" => prompt}] = started_runs()
      assert prompt =~ "cph-qa-#{name}"
      assert prompt =~ "Never invent"

      task = Board.get_task!(task.id)
      assert task.status == :await_human_supervision
      assert task.stage == nil
      # "Approve" names nobody: any human decides.
      assert task.assignee_id == nil
      assert task.findings == []
      assert Engine.ready_to_merge?(task)

      assert [%{kind: :ready_to_merge, title: "Ready to merge: Greet users"} | _] =
               Notifications.recent_notifications!()

      assert Agents.active_runs!() == []

      assert {:ok, %{status: :done}} = Board.move_task(task, :done)
    end

    test "missing reviewers are skipped with a notification", %{bridge: bridge} = context do
      {task, team} = planned_task(context, [])
      Board.approve_plan!(task, team.coder.id)
      BridgeStub.step(bridge)

      assert %{status: :await_human_supervision, stage: nil} = Board.get_task!(task.id)

      assert [:ready_to_merge, :stage_skipped, :stage_skipped | _] = notification_kinds()
    end

    test "findings send the coder back, at most three times", %{bridge: bridge} = context do
      {task, team} = planned_task(context)
      Board.approve_plan!(task, team.coder.id)
      BridgeStub.step(bridge)
      code_session = Board.get_task!(task.id).code_session_id
      flush_bridge()

      for round <- 1..3 do
        BridgeStub.queue(bridge, "reviewer", BridgeStub.findings(1))
        BridgeStub.queue(bridge, "qa", BridgeStub.findings(2))
        BridgeStub.step(bridge)
        BridgeStub.step(bridge)

        task = Board.get_task!(task.id)
        assert %{status: :in_progress, stage: :coding, review_round: ^round} = task
        assert [%{source: :reviewer}, %{source: :qa}, %{source: :qa}] = task.findings

        BridgeStub.step(bridge)
        assert %{status: :review, stage: :code_review} = Board.get_task!(task.id)

        assert [_reviewer, _qa, %{"profile" => "coder", "resume" => ^code_session} = fix] =
                 started_runs()

        assert fix["prompt"] =~ "fix round #{round} of 3"
        assert fix["prompt"] =~ "[qa] f2: Crashes on nil 2"
      end

      BridgeStub.queue(bridge, "reviewer", BridgeStub.findings(1))
      BridgeStub.step(bridge)
      BridgeStub.step(bridge)

      task = Board.get_task!(task.id)
      assert %{status: :await_human_supervision, stage: nil, review_round: 3} = task
      assert [%{source: :reviewer}] = task.findings
      assert Engine.ready_to_merge?(task)

      assert [%{body: "1 findings are still open after 3 fix rounds."} | _] =
               Notifications.recent_notifications!()
    end

    test "a blocked coder waits for answers, then resumes", %{bridge: bridge} = context do
      {task, team} = planned_task(context)
      BridgeStub.queue(bridge, "coder", BridgeStub.outcome("blocked", [BridgeStub.question()]))
      Board.approve_plan!(task, team.coder.id)
      BridgeStub.step(bridge)

      task = Board.get_task!(task.id)
      assert task.status == :await_human_supervision
      assert task.stage == :coding
      assert [%{id: "q1"}] = task.open_questions
      assert hd(notification_kinds()) == :needs_answers
      flush_bridge()

      task = Board.answer_questions!(task, %{"q1" => "No"})
      assert task.status == :in_progress
      BridgeStub.step(bridge)

      assert [%{"profile" => "coder", "resume" => resume, "cwd" => cwd, "prompt" => prompt}] =
               started_runs()

      assert resume == task.code_session_id
      assert cwd == task.worktree_path
      assert prompt =~ "→ No"
      assert Board.get_task!(task.id).stage == :code_review
    end
  end

  describe "review column" do
    defp coded_task(%{bridge: bridge} = context) do
      {task, team} = planned_task(context)
      Board.approve_plan!(task, team.coder.id)
      BridgeStub.step(bridge)
      BridgeStub.step(bridge)
      BridgeStub.step(bridge)
      flush_bridge()
      {Board.get_task!(task.id), team}
    end

    test "a human moving a coded task into review starts the code reviewer again",
         %{bridge: bridge} = context do
      {task, _team} = coded_task(context)
      assert Engine.ready_to_merge?(task)
      Board.advance_task!(task, %{review_round: 3})

      task = Board.move_task!(Board.get_task!(task.id), :review)

      assert %{status: :review, stage: :code_review, review_round: 0, findings: []} = task

      assert [_planning, _coding, _review, _qa, %{stage: :code_review, status: status}] =
               jobs(task)

      assert status in [:before_start, :on_start]

      BridgeStub.step(bridge)
      assert [%{"profile" => "reviewer", "prompt" => prompt}] = started_runs()
      assert prompt =~ BridgeStub.diff()
      assert %{status: :review, stage: :qa} = Board.get_task!(task.id)

      BridgeStub.step(bridge)
      assert %{status: :await_human_supervision, stage: nil} = Board.get_task!(task.id)
    end

    test "a task without code changes is refused", context do
      {task, _team} = planned_task(context)

      assert {:error, %Ash.Error.Invalid{} = error} = Board.move_task(task, :review)
      assert Exception.message(error) =~ "Nothing to review yet: no code changes"
      assert Board.get_task!(task.id).status == :await_human_supervision
      assert [%{stage: :planning}] = jobs(task)
    end

    test "a review that is already queued or running is not started twice", context do
      {task, team} = planned_task(context)
      Board.approve_plan!(task, team.coder.id)
      BridgeStub.step(context.bridge)
      assert %{status: :review, stage: :code_review} = task = Board.get_task!(task.id)

      # Dragged out and back while the reviewer still works on it.
      task = Board.move_task!(task, :in_progress)
      task = Board.move_task!(task, :review)
      assert task.status == :review

      assert [%{stage: :code_review}] =
               Enum.filter(Scheduling.active_jobs!(task.id), &(&1.stage == :code_review))

      assert length(jobs(task)) == 3
    end

    test "moving a task whose coder still works into review stops the coder first",
         %{bridge: bridge} = context do
      {task, team} = planned_task(context)
      Board.approve_plan!(task, team.coder.id)
      Scheduler.dispatch_due()
      flush_bridge()

      task = Board.move_task!(Board.get_task!(task.id), :review)

      assert %{status: :review, stage: :code_review} = task

      assert [_planning, %{stage: :coding, status: :canceled}, %{stage: :code_review}] =
               jobs(task)

      assert_received {:bridge, "POST", "/sessions/" <> _stop, _body}

      BridgeStub.step(bridge)
      assert [%{"profile" => "reviewer"}] = started_runs()
    end
  end

  describe "questions" do
    defp ask(task, question) do
      Board.ask_question!(task.id, question)
    end

    test "a question forks the coder's conversation in its worktree; the task stays put",
         %{bridge: bridge} = context do
      {task, team} = planned_task(context)
      BridgeStub.queue(bridge, "coder", BridgeStub.outcome("blocked", [BridgeStub.question()]))
      Board.approve_plan!(task, team.coder.id)
      BridgeStub.step(bridge)
      task = Board.get_task!(task.id)
      assert %{status: :await_human_supervision, stage: :coding} = task
      flush_bridge()

      assert %{author: :human, kind: :question} = ask(task, "Why Postgres?\nBe brief.")
      assert [%{stage: :ask}] = Scheduling.active_asks!(task.id)
      BridgeStub.step(bridge)

      assert [run] = started_runs()
      assert %{"fork" => true, "profile" => "planner", "jsonSchema" => nil} = run
      assert run["resume"] == task.code_session_id
      assert run["cwd"] == task.worktree_path
      assert run["prompt"] =~ "# Question\n\nWhy Postgres?"

      after_answer = Board.get_task!(task.id)

      assert Map.take(after_answer, [:status, :stage, :code_session_id, :updated_at]) ==
               Map.take(task, [:status, :stage, :code_session_id, :updated_at])

      assert [_plan, _outcome, %{kind: :question}, reply] = Board.list_messages!(task.id)
      assert %{author: :agent, agent_role: :planner, kind: :reply} = reply
      assert reply.body == "Stub answer to: Why Postgres?"

      assert [%{kind: :answer_ready, title: "Answer ready: Greet users"} | _] =
               Notifications.recent_notifications!()

      assert Scheduling.active_asks!(task.id) == []
      refute Engine.restartable?(after_answer)
      assert Agents.active_runs!() == []
    end

    test "before any coding the planner's conversation is forked in the repository",
         %{bridge: bridge} = context do
      {task, _team} = planned_task(context)
      flush_bridge()

      ask(task, "Which file changes?")
      BridgeStub.step(bridge)

      assert [%{"fork" => true, "resume" => resume, "cwd" => "/repos/app"}] = started_runs()
      assert resume == task.plan_session_id
    end

    test "an answerer on another connector than the conversation's starts afresh",
         %{bridge: bridge} = context do
      {task, team} = planned_task(context)
      other = Connectors.create_connector!(%{name: "Other", provider: :claude_code})
      Organization.update_employee!(team.planner, %{agent_role: :planner, connector_id: other.id})
      flush_bridge()

      ask(task, "Which file changes?")
      BridgeStub.step(bridge)

      assert [%{"fork" => false, "resume" => nil} = run] = started_runs()
      assert run["prompt"] =~ "# Task: Greet users"
    end

    test "a task without a conversation gets a fresh run told about the task",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Reviewer", :reviewer)

      task =
        Board.create_task!(%{
          title: "Untouched",
          description: "Rename it",
          repository: "/repos/app"
        })

      ask(task, "Is this hard?")
      BridgeStub.step(bridge)

      assert [%{"resume" => nil, "fork" => false, "profile" => "reviewer"} = run] = started_runs()
      assert run["prompt"] =~ "# Task: Untouched\n\nRename it"
      assert %{status: :backlog, stage: nil} = Board.get_task!(task.id)

      assert [_question, %{kind: :reply, body: "Stub answer to: Is this hard?"}] =
               Board.list_messages!(task.id)
    end

    test "a question runs beside the task's own agent and never holds it up",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Planner", :planner)

      task =
        Board.create_task!(%{title: "Busy", repository: "/repos/app"})

      Board.move_task!(task, :todo)
      Scheduler.dispatch_due()
      assert Board.get_task!(task.id).status == :in_progress

      ask(task, "What are you doing?")
      # Moving to todo again keeps the one planner job: the question is no workflow job.
      Board.move_task!(Board.get_task!(task.id), :todo)
      assert [%{stage: :planning}] = Scheduling.active_jobs!(task.id)

      BridgeStub.step(bridge)

      assert [%{"profile" => "planner", "jsonSchema" => %{}}, %{"jsonSchema" => nil}] =
               started_runs()

      task = Board.get_task!(task.id)
      assert %{status: :await_human_supervision, stage: :planning, plan: %{}} = task
      kinds = Enum.map(Board.list_messages!(task.id), & &1.kind)
      assert Enum.sort(kinds) == Enum.sort([:question, :plan, :reply])
      assert [%{stage: :planning, status: :done}, %{stage: :ask, status: :done}] = jobs(task)
    end

    test "a question nobody can answer is refused", %{connector: connector} do
      agent(connector, "Coder", :coder)
      task = Board.create_task!(%{title: "Alone"})

      assert {:error, error} = Board.ask_question(task.id, "Anyone?")
      assert Exception.message(error) =~ "No agent can answer yet"
      assert {:error, _blank} = Board.ask_question(task.id, "   ")
      assert Board.list_messages!(task.id) == []
      assert jobs(task) == []
    end

    test "a failed answer says so; the task is left as it was",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Planner", :planner)
      task = Board.create_task!(%{title: "Odd", repository: "/repos/app"})
      BridgeStub.queue(bridge, "planner", :fail)

      ask(task, "Why?")
      BridgeStub.step(bridge)

      assert %{status: :backlog} = Board.get_task!(task.id)

      assert [_question, %{kind: :unanswered, body: "Your question could not be answered: " <> _}] =
               Board.list_messages!(task.id)

      assert [%{kind: :agent_failed, title: "Question failed: Odd"} | _] =
               Notifications.recent_notifications!()
    end
  end

  describe "failures" do
    test "a failed run hands the task to a human with a notification",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Planner", :planner)
      BridgeStub.queue(bridge, "planner", :fail)

      task =
        Board.create_task!(%{title: "Doomed", repository: "/repos/app"})

      Board.move_task!(task, :todo)
      BridgeStub.step(bridge)

      assert Board.get_task!(task.id).status == :await_human_supervision

      assert [%{kind: :agent_failed, body: "The agent run failed; see its log."} | _] =
               Notifications.recent_notifications!()

      assert [%{kind: :system}] = Board.list_messages!(task.id)
      assert [%{status: :failed}] = jobs(task)
      assert Agents.active_runs!() == []
    end

    test "a run without structured output counts as failed",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Planner", :planner)
      BridgeStub.queue(bridge, "planner", :no_output)

      task =
        Board.create_task!(%{title: "Mute", repository: "/repos/app"})

      Board.move_task!(task, :todo)
      BridgeStub.step(bridge)

      assert %{status: :await_human_supervision, plan: nil} = Board.get_task!(task.id)

      assert [%{kind: :agent_failed, body: "The agent finished without a structured result."} | _] =
               Notifications.recent_notifications!()
    end

    test "a result that cannot be applied fails its own attempt; the others go on",
         %{bridge: bridge} = context do
      {task, team} = planned_task(context, [])
      reviewer_box = Connectors.create_connector!(%{name: "Reviewer box", provider: :claude_code})
      agent(reviewer_box, "Reviewer", :reviewer)
      Board.approve_plan!(task, team.coder.id)
      BridgeStub.step(bridge)
      assert Board.get_task!(task.id).stage == :code_review

      other =
        Board.create_task!(%{
          title: "Other",
          repository: "/repos/app"
        })

      Board.move_task!(other, :todo)
      Scheduler.dispatch_due()
      Connectors.remove_connector!(reviewer_box)

      log = capture_log(fn -> BridgeStub.step(bridge) end)

      assert log =~ "Scheduler: attempt"
      assert %{status: :await_human_supervision, stage: :code_review} = Board.get_task!(task.id)

      assert %{kind: :agent_failed, body: "The run's result could not be applied: " <> _} =
               Enum.find(Notifications.recent_notifications!(), &(&1.task_id == task.id))

      assert [_planning, _coding, %{stage: :code_review, status: :failed}] = jobs(task)
      assert %{status: :await_human_supervision, plan: %{}} = Board.get_task!(other.id)
    end

    test "a result is consumed once, even when the scheduler sees it again", context do
      {task, _team} = planned_task(context)

      Scheduler.sync_runs(%{run_id(task) => :done})

      assert length(Board.list_messages!(task.id)) == 1
      assert [%{status: :done}] = jobs(task)
    end
  end

  describe "cost ledger" do
    test "a finished run's usage is recorded once, with its agent and task", context do
      {task, team} = planned_task(context)
      run_id = run_id(task)

      assert [usage] = Agents.task_usage!(task.id)

      assert %{
               agent_run_id: ^run_id,
               input_tokens: 1_000,
               output_tokens: 200,
               cache_read_tokens: 3_000,
               cache_creation_tokens: 400,
               duration_ms: 1_500,
               turns: 3
             } = usage

      assert usage.agent_id == team.planner.agent_id
      assert Decimal.equal?(usage.cost_usd, "0.0525")

      Scheduler.sync_runs(%{run_id => :done})
      assert [_once] = Agents.task_usage!(task.id)
    end

    test "a failed run's usage is recorded too", %{bridge: bridge, connector: connector} do
      agent(connector, "Planner", :planner)
      BridgeStub.queue(bridge, "planner", :fail)
      task = Board.create_task!(%{title: "Doomed", repository: "/repos/app"})

      Board.move_task!(task, :todo)
      BridgeStub.step(bridge)

      assert [%{turns: 3}] = Agents.task_usage!(task.id)
    end
  end

  defp run_id(task) do
    [job] = jobs(task)
    [attempt] = Ash.load!(job, :scheduled_jobs).scheduled_jobs
    attempt.agent_run_id
  end

  describe "manual moves" do
    test "moving a running task out of in progress cancels its job; its result is dropped",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Planner", :planner)

      task =
        Board.create_task!(%{title: "Halt", repository: "/repos/app"})

      Board.move_task!(task, :todo)
      Scheduler.dispatch_due()
      assert Board.get_task!(task.id).status == :in_progress
      flush_bridge()

      Board.move_task!(Board.get_task!(task.id), :backlog)
      assert_received {:bridge, "POST", "/sessions/" <> stop, _body}
      assert String.ends_with?(stop, "/stop")
      assert [%{status: :canceled}] = jobs(task)

      BridgeStub.step(bridge)

      assert %{status: :backlog, plan: nil} = Board.get_task!(task.id)
      assert Board.list_messages!(task.id) == []
      assert Agents.active_runs!() == []
    end

    test "deleting a task whose agent runs stops the agent's session",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Planner", :planner)

      task =
        Board.create_task!(%{title: "Gone", repository: "/repos/app"})

      Board.move_task!(task, :todo)
      Scheduler.dispatch_due()
      [run] = Agents.active_runs!()
      flush_bridge()

      Board.destroy_task!(Board.get_task!(task.id))

      stop_path = "/sessions/#{run.session_id}/stop"
      assert_received {:bridge, "POST", ^stop_path, _body}
      assert jobs(task) == []
      assert Agents.active_runs!() == []

      BridgeStub.step(bridge)
      assert Agents.active_runs!() == []
    end

    test "removing an agent that works on a task stops its run; a human takes the task over",
         %{bridge: bridge, connector: connector} do
      planner = agent(connector, "Planner", :planner)

      task =
        Board.create_task!(%{title: "Orphan", repository: "/repos/app"})

      Board.move_task!(task, :todo)
      Scheduler.dispatch_due()
      [run] = Agents.active_runs!()
      flush_bridge()

      Organization.destroy_employee!(Organization.get_employee!(planner.id))

      stop_path = "/sessions/#{run.session_id}/stop"
      assert_received {:bridge, "POST", ^stop_path, _body}
      assert %{status: :await_human_supervision} = Board.get_task!(task.id)
      assert [%{kind: :system, body: body}] = Board.list_messages!(task.id)
      assert body =~ "removed"
      assert hd(notification_kinds()) == :agent_failed

      BridgeStub.step(bridge)
      assert Board.get_task!(task.id).status == :await_human_supervision
    end

    test "moving a task with an active job to todo does not queue a second one",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Planner", :planner)

      task =
        Board.create_task!(%{title: "Twice", repository: "/repos/app"})

      Board.move_task!(task, :todo)
      Scheduler.dispatch_due()
      Board.move_task!(Board.get_task!(task.id), :todo)

      assert [%{status: :in_progress}] = jobs(task)
      BridgeStub.step(bridge)
      assert [%{"profile" => "planner"}] = started_runs()
      assert Board.get_task!(task.id).status == :await_human_supervision
    end
  end

  describe "prompt size" do
    test "a long task reaches the agent whole; a huge one is cut to the bridge's limit",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Planner", :planner)
      long = String.duplicate("x", 50_000)

      task =
        Board.create_task!(%{
          title: "Long",
          description: long,
          repository: "/repos/app"
        })

      Board.move_task!(task, :todo)
      BridgeStub.step(bridge)
      assert [%{"prompt" => prompt}] = started_runs()
      assert prompt =~ long

      huge =
        Prompts.task(%{
          title: "Huge",
          description: String.duplicate("é", 500_000),
          attachment_names: []
        })

      assert String.length(huge) == 400_000
      assert huge =~ "cut to fit the prompt limit"
    end
  end

  describe "a block's own instructions" do
    # The default workflow, with `prompts` (block label => text) saved onto its blocks.
    defp instruct!(prompts) do
      workflow = Workflows.default_workflow!()
      graph = Workflows.graph!(workflow.id)

      nodes =
        for node <- Map.values(graph.nodes) do
          node
          |> Map.take([:id, :kind, :label, :employee_id, :agent_role, :column_status, :x, :y])
          |> Map.merge(%{start: node.start, prompt: prompts[node.label]})
        end

      edges =
        for edge <- graph.edges do
          edge
          |> Map.take([:id, :condition, :iterations, :from_port, :to_port])
          |> Map.merge(%{from: edge.from_node_id, to: edge.to_node_id})
        end

      {:ok, %{problems: []}} = Workflows.save_graph(workflow, %{nodes: nodes, edges: edges})
    end

    @heading "# Instructions for this step (from the workflow)"

    test "reach that block's runs only: after the role's instructions, before the task; resumed runs too",
         %{bridge: bridge} = context do
      instruct!(%{"Coder" => "  Use tabs.  ", "Reviewer" => "Focus on security."})
      {task, team} = planned_task(context)
      assert [%{"prompt" => plan}] = started_runs()
      refute plan =~ @heading

      Board.approve_plan!(task, team.coder.id)
      BridgeStub.queue(bridge, "qa", BridgeStub.findings(1))
      BridgeStub.step(bridge)
      BridgeStub.step(bridge)
      BridgeStub.step(bridge)

      assert [coder, reviewer, qa] = started_runs()

      assert coder["prompt"] =~
               "(empty when done).\n\n#{@heading}\n\nUse tabs.\n\n# Task: Greet users"

      refute coder["prompt"] =~ "Focus on security."
      assert reviewer["prompt"] =~ "#{@heading}\n\nFocus on security.\n\n# Task: Greet users"
      refute reviewer["prompt"] =~ "Use tabs."
      refute qa["prompt"] =~ @heading

      # The fix round resumes the coder's conversation, its instructions first.
      BridgeStub.step(bridge)
      assert [%{"resume" => resume, "prompt" => fix}] = started_runs()
      assert resume
      assert fix =~ ~r/\A#{Regex.escape(@heading)}\n\nUse tabs\.\n\nThe reviewers found/
    end

    test "are saved with the graph, copied with the workflow, and capped at 20,000 characters" do
      instruct!(%{"Reviewer" => "Focus on security.", "Coder" => "   "})
      graph = Workflows.graph!(Workflows.default_workflow!().id)
      prompts = Map.new(Map.values(graph.nodes), &{&1.label, &1.prompt})
      assert %{"Reviewer" => "Focus on security.", "Coder" => nil} = prompts

      copy = Workflows.create_workflow!("Copy", Workflows.default_workflow!().id)

      copied =
        Workflows.graph!(copy.id).nodes |> Map.values() |> Enum.find(&(&1.label == "Reviewer"))

      assert copied.prompt == "Focus on security."

      workflow = Workflows.default_workflow!()
      reviewer = Enum.find(Map.values(graph.nodes), &(&1.label == "Reviewer"))

      params = %{
        nodes: [
          %{
            id: reviewer.id,
            kind: "agent",
            label: "Reviewer",
            agent_role: "reviewer",
            start: true,
            prompt: String.duplicate("a", 20_001)
          }
        ],
        edges: []
      }

      assert {:error, [%{id: id, message: "Instructions can be at most 20,000 characters"}]} =
               Workflows.save_graph(workflow, params)

      assert id == reviewer.id
    end
  end

  describe "a block's own timeouts" do
    defp limit!(label, limits) do
      workflow = Workflows.default_workflow!()
      params = Workflows.params(Workflows.graph!(workflow.id))

      nodes =
        Enum.map(params.nodes, fn node ->
          if node.label == label, do: Map.merge(node, limits), else: node
        end)

      Workflows.save_graph(workflow, %{params | nodes: nodes})
    end

    test "reach its jobs", context do
      {:ok, %{problems: []}} =
        limit!("Planner", %{stall_timeout_minutes: 3, turn_timeout_minutes: 30})

      {task, _team} = planned_task(context)
      [planner] = Scheduling.task_jobs!(task.id)
      assert %{stall_timeout_minutes: 3, turn_timeout_minutes: 30} = planner
    end

    test "left blank keep the job's defaults", context do
      {:ok, %{problems: []}} = limit!("Planner", %{stall_timeout_minutes: nil})
      {task, _team} = planned_task(context)
      [planner] = Scheduling.task_jobs!(task.id)
      assert %{stall_timeout_minutes: 15, turn_timeout_minutes: 120} = planner
    end

    test "are whole minutes from 1 to 1440" do
      for minutes <- [0, 1441, "soon"] do
        assert {:error, [%{message: "Timeouts must be whole minutes from 1 to 1440"}]} =
                 limit!("Coder", %{turn_timeout_minutes: minutes})
      end
    end
  end

  describe "attachments" do
    test "attached files reach the run's working directory and its prompt lists them",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Planner", :planner)

      task =
        Board.create_task!(%{
          title: "Match the mockup",
          repository: "/repos/app"
        })

      png = <<137, 80, 78, 71>>
      Board.attach_file!(%{task_id: task.id, file_name: "../mocké.png", content: png})
      # The same name again replaces the file.
      Board.attach_file!(%{task_id: task.id, file_name: "mocké.png", content: png <> png})

      Board.move_task!(task, :todo)
      BridgeStub.step(bridge)

      folder = Engine.short_id(task)
      assert [%{"prompt" => prompt, "attachments" => attachments}] = started_runs()
      assert prompt =~ "- `.weworkai/attachments/#{folder}/mock_.png`"

      assert attachments == %{
               "folder" => folder,
               "files" => [%{"name" => "mock_.png", "content" => Base.encode64(png <> png)}]
             }
    end
  end

  describe "default agents" do
    test "with only a connected connector, each role block makes its default agent and runs it",
         %{bridge: bridge, connector: connector} do
      connector = with_status(connector, :connected)

      task =
        Board.create_task!(%{
          title: "Greet users",
          description: "Say hello",
          repository: "/repos/app"
        })

      Board.move_task!(task, :todo)
      BridgeStub.step(bridge)

      assert [%{"profile" => "planner", "model" => "claude-opus-5-5"}] = started_runs()
      task = Board.get_task!(task.id)
      assert %{status: :await_human_supervision, stage: :planning} = task

      assert [%{name: "Planner", agent: %{role: :planner, model: "claude-opus-5-5"} = planner}] =
               Organization.list_all_employees!(load: [agent: :connector_link])

      assert planner.connector_link.connector_id == connector.id

      Board.approve_plan!(task)
      BridgeStub.step(bridge)
      BridgeStub.step(bridge)
      BridgeStub.step(bridge)

      assert ["coder", "reviewer", "qa"] = Enum.map(started_runs(), & &1["profile"])
      assert Engine.ready_to_merge?(Board.get_task!(task.id))
      refute :stage_skipped in notification_kinds()

      assert ["Coder", "Docker reviewer", "Planner", "Reviewer"] =
               Enum.map(Organization.list_all_employees!(), & &1.name)
    end

    test "a role that has an agent gets no default one", %{bridge: bridge, connector: connector} do
      ada = agent(with_status(connector, :connected), "Ada", :planner)
      task = Board.create_task!(%{title: "Greet users", repository: "/repos/app"})
      Board.move_task!(task, :todo)
      BridgeStub.step(bridge)

      assert [%{id: id}] = Organization.list_all_employees!()
      assert id == ada.id
    end

    test "without a connected connector a role nobody has is refused", %{connector: connector} do
      with_status(connector, :error)
      task = Board.create_task!(%{title: "Bare"})

      assert {:error, %Ash.Error.Invalid{errors: [error]}} =
               Board.continue_task(task, block_id(task, "Coder"))

      assert ErrorText.readable(error) ==
               "Coder can't run: No coder agent yet. Add one on the Employees page."

      assert Organization.list_all_employees!() == []
    end
  end

  describe "preconditions" do
    test "a task left without a repository works in ~/Projects" do
      assert Board.create_task!(%{title: "Where?"}).repository == "~/Projects"
      task = Board.create_task!(%{title: "Blank", repository: "  "})
      assert task.repository == "~/Projects"

      task = Board.update_task!(task, %{repository: "/repos/app"})
      assert Board.update_task!(task, %{repository: ""}).repository == "~/Projects"
    end

    test "an agent that can't run cannot pick a task up", %{connector: connector} do
      _planner =
        Organization.create_employee!(%{
          kind: :agent,
          name: "E2E Planner",
          agent_role: :planner,
          connector_id: connector.id
        })

      task = Board.create_task!(%{title: "Plan it"})

      assert {:error, %Ash.Error.Invalid{errors: [error]}} = Board.move_task(task, :todo)

      assert ErrorText.readable(error) ==
               "Planner can't run: E2E Planner has no model yet. Configure it on the Employees page."

      assert jobs(task) == []
      assert Board.get_task!(task.id).status == :backlog

      # Any planner that can run takes it, and becomes the task's assignee.
      spare = agent(connector, "Spare planner", :planner)

      assert {:ok, %{status: :todo, stage: :planning, assignee_id: assignee}} =
               Board.move_task(task, :todo)

      assert assignee == spare.id
      assert [%{stage: :planning}] = jobs(task)
    end

    test "without a pick the plan goes to the first coder that can run; a pick pins one",
         context do
      {task, team} = planned_task(context)
      assert %{assignee_id: first, pinned_coder_id: nil} = Board.approve_plan!(task)
      assert first == team.coder.id

      {task, _team} = planned_task(context)
      second = agent(context.connector, "Second coder", :coder)

      assert %{assignee_id: pinned, pinned_coder_id: pinned} =
               Board.approve_plan!(task, second.id)

      assert pinned == second.id
    end

    test "only a plan waiting for a human can be approved, and only for a coder", context do
      {task, team} = planned_task(context)

      assert {:error, %Ash.Error.Invalid{}} = Board.approve_plan(task, team.reviewer.id)

      in_progress = Board.comment_on_plan!(task, "Shorter")
      assert {:error, %Ash.Error.Invalid{}} = Board.approve_plan(in_progress, team.coder.id)
      assert {:error, %Ash.Error.Invalid{}} = Board.comment_on_plan(in_progress, "Again")
    end

    test "a plan goes only to a coder that can run", context do
      {task, team} = planned_task(context)

      unconfigured =
        Organization.create_employee!(%{
          kind: :agent,
          name: "New coder",
          agent_role: :coder,
          connector_id: context.connector.id
        })

      assert {:error, %Ash.Error.Invalid{}} = Board.approve_plan(task, unconfigured.id)
      assert [%{stage: :planning}] = jobs(task)
      assert {:ok, %{status: :todo}} = Board.approve_plan(task, team.coder.id)
    end

    test "a plan takes one response; a second tab acting on the same page is refused",
         context do
      {task, team} = planned_task(context)

      assert {:ok, _} = Board.comment_on_plan(task, "Shorter")
      assert {:error, %Ash.Error.Invalid{}} = Board.comment_on_plan(task, "Longer")
      assert {:error, %Ash.Error.Invalid{}} = Board.answer_questions(task, %{"q1" => "No"})
      assert {:error, %Ash.Error.Invalid{}} = Board.approve_plan(task, team.coder.id)

      assert [%{resume: nil}, %{resume: resume}] = jobs(task)
      assert resume == task.plan_session_id
      assert %{status: :in_progress, plan_approved_at: nil} = Board.get_task!(task.id)
    end

    test "answers for questions a newer agent result replaced are refused", context do
      {task, _team} = planned_task(context)

      Board.advance_task!(Board.get_task!(task.id), %{
        open_questions: [%{id: "q1", question: "Which locale first?", options: []}]
      })

      assert {:error, %Ash.Error.Invalid{}} = Board.answer_questions(task, %{"q1" => "No"})
      assert [%{resume: nil}] = jobs(task)

      current = Board.get_task!(task.id)
      assert {:ok, %{status: :in_progress}} = Board.answer_questions(current, %{"q1" => "German"})
    end

    test "answers need open questions; comments need a plan", %{connector: connector} do
      agent(connector, "Planner", :planner)

      task =
        Board.create_task!(%{title: "Fresh", repository: "/repos/app"})

      waiting = Board.advance_task!(task, %{status: :await_human_supervision, stage: :planning})

      assert {:error, %Ash.Error.Invalid{}} = Board.answer_questions(waiting, %{"q1" => "x"})
      assert {:error, %Ash.Error.Invalid{}} = Board.comment_on_plan(waiting, "Hm")
    end

    test "answers must cover exactly the open questions", context do
      {task, _team} = planned_task(context)

      for answers <- [%{}, %{"q1" => "No", "q9" => "Yes"}, %{"q9" => "Yes"}, %{"q1" => "  "}] do
        assert {:error, %Ash.Error.Invalid{}} = Board.answer_questions(task, answers)
      end

      assert {:ok, %{status: :in_progress}} = Board.answer_questions(task, %{"q1" => "No"})
    end
  end

  describe "continue" do
    defp labels(targets), do: Enum.map(targets, & &1.label)

    defp set_model(employee, model) do
      agent = Agents.get_agent!(employee.agent_id)

      agent
      |> Ash.Changeset.for_update(:assign_role, %{role: agent.role})
      |> Ash.Changeset.force_change_attributes(%{model: model})
      |> Ash.update!()
    end

    defp failed_start(%{bridge: bridge, connector: connector}) do
      planner = agent(connector, "Planner", :planner)
      task = Board.create_task!(%{title: "Retry me"})
      Board.move_task!(task, :todo)
      # The model was removed after the move, so the start itself fails.
      set_model(planner, nil)
      BridgeStub.step(bridge)
      flush_bridge()
      {Board.get_task!(task.id), planner}
    end

    # Coded before the review column: in review with no stage, reviewers never ran.
    defp coded_but_unreviewed(%{bridge: bridge} = context, roles) do
      {task, team} = planned_task(context, roles)
      Board.approve_plan!(task, team.coder.id)
      Scheduler.dispatch_due()
      flush_bridge()
      [_planning, coding] = jobs(task)
      Scheduling.cancel_job!(coding)

      task =
        task.id
        |> Board.get_task!()
        |> Board.advance_task!(%{
          status: :review,
          stage: nil,
          code_session_id: Ecto.UUID.generate()
        })

      BridgeStub.step(bridge)
      {task, team}
    end

    test "after the agent is fixed, Continue starts its failed stage again", context do
      {task, planner} = failed_start(context)
      assert task.status == :await_human_supervision

      assert labels(Board.continue_targets(task)) ==
               ["Planner", "Approve plan", "Coder", "Approve", "Mark done"]

      assert {:error, %Ash.Error.Invalid{errors: [error]}} = Board.continue_task(task)

      assert ErrorText.readable(error) ==
               "Planner can't run: Planner has no model yet. Configure it on the Employees page."

      set_model(planner, "claude-opus-5-5")
      task = Board.continue_task!(task)
      assert %{status: :todo, stage: :planning} = task

      Scheduler.dispatch_due()

      assert [%{"profile" => "planner", "resume" => nil, "cwd" => "~/Projects"}] = started_runs()
      assert %{status: :in_progress} = Board.get_task!(task.id)

      assert [
               %{kind: :system, author: :agent},
               %{kind: :restart, author: :human, body: "Continued by you → Planner"}
             ] = Board.list_messages!(task.id)

      assert [_failed, %{status: :in_progress}] = jobs(task)
    end

    test "a planner that already talked carries on in its conversation",
         %{bridge: bridge} = context do
      {task, _team} = planned_task(context)
      flush_bridge()
      BridgeStub.queue(bridge, "planner", :fail)
      task = Board.comment_on_plan!(task, "Shorter")
      BridgeStub.step(bridge)
      flush_bridge()

      task = Board.get_task!(task.id)
      Board.continue_task!(task)
      BridgeStub.step(bridge)

      assert [%{"profile" => "planner", "resume" => resume, "prompt" => prompt}] = started_runs()
      assert resume == task.plan_session_id
      assert prompt =~ "carry on"
      assert Board.get_task!(task.id).status == :await_human_supervision
    end

    test "a stuck job is canceled, its session stopped, and its stage started again", context do
      agent(context.connector, "Planner", :planner)
      task = Board.create_task!(%{title: "Stuck"})
      Board.move_task!(task, :todo)
      Scheduler.dispatch_due()
      [run] = Agents.active_runs!()
      flush_bridge()

      Board.continue_task!(Board.get_task!(task.id))

      stop_path = "/sessions/#{run.session_id}/stop"
      assert_received {:bridge, "POST", ^stop_path, _body}
      Scheduler.dispatch_due()
      assert [%{status: :canceled}, %{status: :in_progress, stage: :planning}] = jobs(task)
    end

    test "a coded task stuck in review: Continue offers review and names the reviewer's missing model",
         context do
      {task, _team} = coded_but_unreviewed(context, [])

      Organization.create_employee!(%{
        kind: :agent,
        name: "Reviewer",
        agent_role: :reviewer,
        connector_id: context.connector.id
      })

      assert labels(Board.continue_targets(task)) ==
               [
                 "Coder",
                 "Planner",
                 "Approve plan",
                 "Reviewer",
                 "Docker reviewer",
                 "Approve",
                 "Mark done"
               ]

      assert {:error, %Ash.Error.Invalid{errors: [error]}} =
               Board.continue_task(task, block_id(task, "Reviewer"))

      assert ErrorText.readable(error) ==
               "Reviewer can't run: Reviewer has no model yet. Configure it on the Employees page."

      assert %{status: :review, stage: nil} = Board.get_task!(task.id)
    end

    test "Continue → review runs the reviewers; a role with no agent at all is skipped",
         %{bridge: bridge} = context do
      {task, _team} = coded_but_unreviewed(context, [:reviewer])

      task = Board.continue_task!(task, block_id(task, "Reviewer"))
      assert %{status: :review, stage: :code_review, review_round: 0} = task

      BridgeStub.step(bridge)
      assert [%{"profile" => "reviewer"}] = started_runs()
      assert %{status: :await_human_supervision, stage: nil} = task = Board.get_task!(task.id)
      assert Engine.ready_to_merge?(task)
      assert [:ready_to_merge, :stage_skipped | _] = notification_kinds()
    end

    test "Continue → coding resumes the coder with a carry-on prompt",
         %{bridge: bridge} = context do
      {task, _team} = coded_but_unreviewed(context, [])

      task = Board.continue_task!(task, block_id(task, "Coder"))
      assert %{status: :todo, stage: :coding} = task
      Scheduler.dispatch_due()

      assert [%{"profile" => "coder", "resume" => resume, "cwd" => cwd, "prompt" => prompt}] =
               started_runs()

      assert resume == task.code_session_id
      assert cwd == task.worktree_path
      assert prompt =~ "carry on"
      BridgeStub.step(bridge)
    end

    test "what is missing is named: no agent in the role, a block gone from the workflow" do
      task = Board.create_task!(%{title: "Bare"})

      assert {:error, %Ash.Error.Invalid{errors: [error]}} =
               Board.continue_task(task, block_id(task, "Coder"))

      assert ErrorText.readable(error) ==
               "Coder can't run: No coder agent yet. Add one on the Employees page."

      assert {:error, %Ash.Error.Invalid{errors: [error]}} =
               Board.continue_task(task, block_id(task, "Planner"))

      assert ErrorText.readable(error) ==
               "Planner can't run: No planner agent yet. Add one on the Employees page."

      assert {:error, %Ash.Error.Invalid{errors: [error]}} =
               Board.continue_task(task, Ecto.UUID.generate())

      assert ErrorText.readable(error) == "That block is no longer in this task's workflow."

      assert {:ok, %{status: :done}} = Board.continue_task(task, "done")
    end

    test "a second tab continuing the same copy is refused", context do
      {task, _team} = planned_task(context)

      assert {:ok, _} = Board.continue_task(task)
      assert {:error, %Ash.Error.Invalid{}} = Board.continue_task(task)
      assert [_done, %{status: status}] = jobs(task)
      assert status in [:before_start, :on_start]
    end
  end

  describe "custom workflows" do
    defp block(id, kind, fields),
      do: Map.merge(%{id: id, kind: kind, label: fields[:label] || id}, Map.new(fields))

    defp arrow(id, from, to, condition \\ nil, iterations \\ nil),
      do: %{id: id, from: from, to: to, condition: condition, iterations: iterations}

    defp workflow!(name, nodes, edges) do
      workflow = Workflows.create_workflow!(name)
      assert {:ok, _saved} = Workflows.save_graph(workflow, %{nodes: nodes, edges: edges})
      workflow
    end

    defp start!(workflow, title \\ "Greet users") do
      task =
        Board.create_task!(%{
          title: title,
          description: "Say hello",
          repository: "/repos/app",
          workflow_id: workflow.id
        })

      Board.move_task!(task, :todo)
    end

    defp current_label(task) do
      task = Board.get_task!(task.id, load: :current_node)
      task.current_node && task.current_node.label
    end

    defp profiles(runs), do: Enum.map(runs, & &1["profile"])

    test "a task created with another workflow runs that one", %{
      bridge: bridge,
      connector: connector
    } do
      team(connector, [:planner, :coder])

      lean =
        workflow!(
          "Lean",
          [
            block("c", :agent, agent_role: :coder, label: "Coder"),
            block("d", :column, column_status: :done)
          ],
          [arrow("e", "c", "d", "done")]
        )

      task = start!(lean)
      assert task.workflow_id == lean.id
      assert task.worktree_branch
      BridgeStub.step(bridge)

      assert ["coder"] = profiles(started_runs())
      assert %{status: :done, current_node_id: nil, stage: nil} = Board.get_task!(task.id)
      assert Board.create_task!(%{title: "Other"}).workflow_id == Workflows.default_workflow!().id
    end

    test "a self-loop runs the reviewer twice in a row, then goes on", %{
      bridge: bridge,
      connector: connector
    } do
      team(connector, [:coder, :reviewer])

      twice =
        workflow!(
          "Review twice",
          [
            block("c", :agent, agent_role: :coder, label: "Coder", start: true),
            block("r", :agent, agent_role: :reviewer, label: "Reviewer", x: 1),
            block("d", :column, column_status: :done, x: 2)
          ],
          [
            arrow("e1", "c", "r", "done"),
            arrow("loop", "r", "r", nil, 2),
            arrow("e2", "r", "d", "clean")
          ]
        )

      task = start!(twice)
      for _run <- 1..3, do: BridgeStub.step(bridge)

      assert ["coder", "reviewer", "reviewer"] = profiles(started_runs())
      assert %{status: :done} = Board.get_task!(task.id)
    end

    test "findings send the coder back at most as often as the arrow allows, then the work goes on",
         %{bridge: bridge, connector: connector} do
      team(connector, [:coder, :reviewer])

      capped =
        workflow!(
          "Two fix rounds",
          [
            block("c", :agent, agent_role: :coder, label: "Coder", start: true),
            block("r", :agent, agent_role: :reviewer, label: "Reviewer", x: 1),
            block("h", :human, label: "Check", x: 2),
            block("d", :column, column_status: :done, x: 3)
          ],
          [
            arrow("e1", "c", "r", "done"),
            arrow("back", "r", "c", "findings", 2),
            arrow("e2", "r", "h", "clean"),
            arrow("e3", "h", "d", "merged")
          ]
        )

      for _round <- 1..3, do: BridgeStub.queue(bridge, "reviewer", BridgeStub.findings(1))
      task = start!(capped)
      for _run <- 1..6, do: BridgeStub.step(bridge)

      runs = started_runs()
      assert ["coder", "reviewer", "coder", "reviewer", "coder", "reviewer"] = profiles(runs)
      assert Enum.at(runs, 4)["prompt"] =~ "fix round 2 of 2"

      task = Board.get_task!(task.id)
      assert %{status: :await_human_supervision, stage: nil, review_round: 2} = task
      back = Enum.find(Workflows.graph!(capped.id).edges, &(&1.condition == "findings"))
      assert task.edge_counts[back.id] == 2
      assert current_label(task) == "Check"
      assert Engine.ready_to_merge?(task)

      assert [%{kind: :ready_to_merge, body: "1 findings are still open after 2 fix rounds."} | _] =
               Notifications.recent_notifications!()
    end

    test "a triage block sends only high findings back to the coder; the rest go to a human",
         %{bridge: bridge, connector: connector} do
      team(connector, [:coder, :reviewer])

      triaged =
        workflow!(
          "Triaged",
          [
            block("c", :agent, agent_role: :coder, label: "Coder", start: true),
            block("r", :agent, agent_role: :reviewer, label: "Reviewer", x: 1),
            block("t", :triage, label: "Triage", x: 2),
            block("h", :human, label: "Approve", x: 3),
            block("d", :column, column_status: :done, x: 4)
          ],
          [
            arrow("e1", "c", "r", "done"),
            arrow("e2", "r", "t"),
            arrow("serious", "t", "c", "high", 2),
            arrow("rest", "t", "h"),
            arrow("e3", "h", "d", "accepted")
          ]
        )

      low =
        update_in(
          BridgeStub.findings(1)["findings"],
          &Enum.map(&1, fn finding -> %{finding | "severity" => "low"} end)
        )

      BridgeStub.queue(bridge, "reviewer", BridgeStub.findings(1))
      BridgeStub.queue(bridge, "reviewer", low)
      task = start!(triaged)
      for _run <- 1..4, do: BridgeStub.step(bridge)

      runs = started_runs()
      assert ["coder", "reviewer", "coder", "reviewer"] = profiles(runs)
      assert Enum.at(runs, 2)["prompt"] =~ "fix round 1 of 2"

      task = Board.get_task!(task.id)
      assert %{status: :await_human_supervision, review_round: 1} = task
      assert [%{severity: :low}] = task.findings
      assert current_label(task) == "Approve"
      assert Engine.ready_to_merge?(task)
    end

    test "a triage block without an arrow for the outcome leaves the task with a human",
         %{bridge: bridge, connector: connector} do
      team(connector, [:coder, :reviewer])

      strict =
        workflow!(
          "Strict",
          [
            block("c", :agent, agent_role: :coder, label: "Coder", start: true),
            block("r", :agent, agent_role: :reviewer, label: "Reviewer", x: 1),
            block("t", :triage, label: "Triage", x: 2),
            block("d", :column, column_status: :done, x: 3)
          ],
          [
            arrow("e1", "c", "r", "done"),
            arrow("e2", "r", "t"),
            arrow("ok", "t", "d", "clean")
          ]
        )

      BridgeStub.queue(bridge, "reviewer", BridgeStub.findings(1))
      task = start!(strict)
      for _run <- 1..2, do: BridgeStub.step(bridge)

      task = Board.get_task!(task.id)
      assert %{status: :await_human_supervision} = task
      assert current_label(task) == "Triage"
      assert :workflow_stuck in notification_kinds()

      assert Enum.any?(
               Board.list_messages!(task.id),
               &(&1.body == "Triage has no arrow for “high”.")
             )
    end

    test "a human decides between two arrows: back into the group (its agents resume), or done",
         %{bridge: bridge, connector: connector} do
      team(connector, [:coder, :reviewer])

      grouped =
        workflow!(
          "Grouped",
          [
            block("g", :group, label: "Build", start: true),
            block("c", :agent, agent_role: :coder, label: "Coder", group_id: "g", x: 1),
            block("r", :agent, agent_role: :reviewer, label: "Reviewer", group_id: "g", x: 2),
            block("h", :human, label: "Accept?", x: 3),
            block("d", :column, column_status: :done, x: 4)
          ],
          [
            arrow("inner", "c", "r", "done"),
            arrow("out", "g", "h", "clean"),
            arrow("yes", "h", "d", "accepted"),
            arrow("no", "h", "g", "not accepted")
          ]
        )

      task = start!(grouped)
      assert current_label(task) == "Coder"
      BridgeStub.step(bridge)
      BridgeStub.step(bridge)
      assert ["coder", "reviewer"] = profiles(started_runs())

      task = Board.get_task!(task.id)
      assert %{status: :await_human_supervision} = task
      assert current_label(task) == "Accept?"
      graph = Workflows.graph!(grouped.id)
      # In the order their targets are drawn.
      assert ["not accepted", "accepted"] =
               Enum.map(Engine.decisions(task, graph), & &1.edge.condition)

      %{edge: back} =
        Enum.find(Engine.decisions(task, graph), &(&1.edge.condition == "not accepted"))

      task = Board.decide_task!(task, back.id, "Handle nil names too")
      assert current_label(task) == "Coder"
      assert {:error, %Ash.Error.Invalid{}} = Board.decide_task(task, back.id)
      BridgeStub.step(bridge)
      BridgeStub.step(bridge)

      assert [
               %{"profile" => "coder", "resume" => resume, "prompt" => prompt},
               %{"profile" => "reviewer"}
             ] =
               started_runs()

      assert resume == task.code_session_id
      assert prompt =~ "decided: “not accepted”"
      assert prompt =~ "# Their comment\n\nHandle nil names too"

      task = Board.get_task!(task.id)
      %{edge: yes} = Enum.find(Engine.decisions(task, graph), &(&1.edge.condition == "accepted"))
      assert %{status: :done, current_node_id: nil} = Board.decide_task!(task, yes.id)

      assert [
               %{kind: :decision, body: "Decided: not accepted\n\nHandle nil names too"},
               %{kind: :decision, body: "Decided: accepted"}
             ] =
               Enum.filter(Board.list_messages!(task.id), &(&1.kind == :decision))
    end

    test "a column block moves the task and passes it on; without an arrow it stays",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Helper", :custom)

      columns =
        workflow!(
          "Columns",
          [
            block("a", :agent, agent_role: :custom, label: "Helper", start: true),
            block("review", :column, column_status: :review, label: "To review", x: 1),
            block("shelf", :column, column_status: :backlog, label: "Shelf", x: 2)
          ],
          [arrow("e1", "a", "review", "done"), arrow("e2", "review", "shelf")]
        )

      task = start!(columns)
      BridgeStub.step(bridge)

      assert ["custom"] = profiles(started_runs())
      task = Board.get_task!(task.id)
      assert %{status: :backlog} = task
      assert current_label(task) == "Shelf"
    end

    test "a task whose block was removed from its workflow goes on by the version it runs",
         %{bridge: bridge, connector: connector} do
      team(connector, [:planner])
      BridgeStub.queue(bridge, "planner", BridgeStub.plan([]))
      copy = Workflows.create_workflow!("Copy")
      task = start!(copy)
      Scheduler.dispatch_due()

      assert {:ok, %{workflow: %{version: 2}}} =
               Workflows.save_graph(copy, %{
                 nodes: [block("x", :agent, agent_role: :custom, label: "Other")],
                 edges: []
               })

      BridgeStub.step(bridge)

      assert %{status: :await_human_supervision, workflow_version: 1} = Board.get_task!(task.id)
      assert current_label(task) == "Approve plan"
      assert [%{kind: :plan}] = Board.list_messages!(task.id)
    end

    test "an outcome without an arrow goes to a human, naming the block", %{
      bridge: bridge,
      connector: connector
    } do
      team(connector, [:coder])

      dead_end =
        workflow!(
          "Dead end",
          [
            block("c", :agent, agent_role: :coder, label: "Coder"),
            block("d", :column, column_status: :done)
          ],
          [arrow("e", "c", "d", "blocked")]
        )

      task = start!(dead_end)
      BridgeStub.step(bridge)

      assert %{status: :await_human_supervision} = Board.get_task!(task.id)

      assert [_outcome, %{kind: :system, body: "Coder has no arrow for “done”."}] =
               Board.list_messages!(task.id)
    end
  end

  describe "graph runtime" do
    defp decision(task, condition) do
      graph = Workflows.graph!(task.workflow_id)
      Enum.find(Engine.decisions(task, graph), &(&1.edge.condition == condition)).edge
    end

    test "a task started over from its start block gets the arrows' caps afresh",
         %{bridge: bridge, connector: connector} do
      team(connector, [:coder, :reviewer])

      capped =
        workflow!(
          "One fix round",
          [
            block("c", :agent, agent_role: :coder, label: "Coder", start: true),
            block("r", :agent, agent_role: :reviewer, label: "Reviewer", x: 1),
            block("d", :column, column_status: :done, x: 2)
          ],
          [
            arrow("e1", "c", "r", "done"),
            arrow("back", "r", "c", "findings", 1),
            arrow("e2", "r", "d", "clean")
          ]
        )

      BridgeStub.queue(bridge, "reviewer", BridgeStub.findings(1))
      task = start!(capped)
      for _run <- 1..4, do: BridgeStub.step(bridge)
      assert ["coder", "reviewer", "coder", "reviewer"] = profiles(started_runs())
      assert %{status: :done, review_round: 1} = task = Board.get_task!(task.id)

      task = Board.move_task!(task, :todo)
      assert %{review_round: 0, findings: [], edge_counts: counts} = task
      assert counts == %{}
      assert task.node_counts == %{block_id(task, "Coder") => 1}
      BridgeStub.queue(bridge, "reviewer", BridgeStub.findings(1))
      for _run <- 1..3, do: BridgeStub.step(bridge)

      assert ["coder", "reviewer", "coder"] = profiles(runs = started_runs())
      assert List.last(runs)["prompt"] =~ "fix round 1 of 1"
    end

    test "moving a task parked on a column block to todo starts its workflow over",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Helper", :custom)

      parked =
        workflow!(
          "Parked",
          [
            block("a", :agent, agent_role: :custom, label: "Helper", start: true),
            block("shelf", :column, column_status: :backlog, label: "Shelf", x: 1)
          ],
          [arrow("e1", "a", "shelf", "done")]
        )

      task = start!(parked)
      BridgeStub.step(bridge)
      assert %{status: :backlog} = task = Board.get_task!(task.id)
      assert current_label(task) == "Shelf"

      assert %{status: :todo} = task = Board.move_task!(task, :todo)
      assert current_label(task) == "Helper"
      BridgeStub.step(bridge)
      assert ["custom", "custom"] = profiles(started_runs())
    end

    test "a decision's comment reaches an agent that starts afresh",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Helper", :custom)

      decided =
        workflow!(
          "Decided",
          [
            block("h", :human, label: "Go?", start: true),
            block("a", :agent, agent_role: :custom, label: "Helper", x: 1)
          ],
          [arrow("go", "h", "a", "go")]
        )

      task = start!(decided)
      assert %{status: :await_human_supervision} = task
      Board.decide_task!(task, decision(task, "go").id, "Use the short greeting")
      BridgeStub.step(bridge)

      assert [%{"profile" => "custom", "prompt" => prompt}] = started_runs()
      assert prompt =~ "Say hello"
      assert prompt =~ "decided: “go”"
      assert prompt =~ "Use the short greeting"
    end

    test "a block a task can't enter inside a group is where it waits, and Continue's default",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Helper", :custom)

      grouped =
        workflow!(
          "Grouped",
          [
            block("a", :agent, agent_role: :custom, label: "Helper", start: true),
            block("g", :group, label: "Build", x: 1),
            block("c", :agent, agent_role: :coder, label: "Coder", group_id: "g", x: 1),
            block("d", :column, column_status: :done, x: 2)
          ],
          [arrow("e1", "a", "g", "done"), arrow("e2", "g", "d")]
        )

      task = start!(grouped)
      BridgeStub.step(bridge)

      assert %{status: :await_human_supervision} = task = Board.get_task!(task.id)
      assert current_label(task) == "Coder"
      assert [%{label: "Coder"} | _] = Board.continue_targets(task)
    end

    test "a coder block entered again by an arrow is not told a human asked",
         %{bridge: bridge, connector: connector} do
      team(connector, [:coder])

      two_coders =
        workflow!(
          "Two coders",
          [
            block("c1", :agent, agent_role: :coder, label: "Coder A", start: true),
            block("c2", :agent, agent_role: :coder, label: "Coder B", x: 1),
            block("d", :column, column_status: :done, x: 2)
          ],
          [arrow("e1", "c1", "c2", "done"), arrow("e2", "c2", "d", "done")]
        )

      task = start!(two_coders)
      BridgeStub.step(bridge)
      BridgeStub.step(bridge)

      assert [first, %{"resume" => resume, "prompt" => prompt}] = started_runs()
      assert first["resume"] == nil
      # One coder conversation per task: Coder B knows what Coder A did.
      assert resume == Board.get_task!(task.id).code_session_id
      refute prompt =~ "A human asked"
      assert prompt =~ "Coder B"
      assert %{status: :done} = Board.get_task!(task.id)
    end

    test "fix rounds through a group's loop are counted against the loop's runs",
         %{bridge: bridge, connector: connector} do
      team(connector, [:coder, :reviewer])

      looped =
        workflow!(
          "Group loop",
          [
            block("g", :group, label: "Build", start: true),
            block("c", :agent, agent_role: :coder, label: "Coder", group_id: "g", x: 1),
            block("r", :agent, agent_role: :reviewer, label: "Reviewer", group_id: "g", x: 2),
            block("d", :column, column_status: :done, x: 3)
          ],
          [
            arrow("inner", "c", "r", "done"),
            arrow("loop", "g", "g", "findings", 3),
            arrow("out", "g", "d")
          ]
        )

      for _round <- 1..3, do: BridgeStub.queue(bridge, "reviewer", BridgeStub.findings(1))
      task = start!(looped)
      for _run <- 1..6, do: BridgeStub.step(bridge)

      runs = started_runs()
      assert ["coder", "reviewer", "coder", "reviewer", "coder", "reviewer"] = profiles(runs)
      assert Enum.at(runs, 2)["prompt"] =~ "fix round 1 of 2"
      assert Enum.at(runs, 4)["prompt"] =~ "fix round 2 of 2"
      assert %{status: :done, review_round: 2} = Board.get_task!(task.id)
    end

    test "a blocked coder that ends its group follows the group's arrow for it",
         %{bridge: bridge, connector: connector} do
      team(connector, [:coder])

      grouped =
        workflow!(
          "Blocked group",
          [
            block("g", :group, label: "Build", start: true),
            block("c", :agent, agent_role: :coder, label: "Coder", group_id: "g", x: 1),
            block("h", :human, label: "Help", x: 2),
            block("d", :column, column_status: :done, x: 3)
          ],
          [
            arrow("stuck", "g", "h", "blocked"),
            arrow("out", "g", "d", "done"),
            arrow("retry", "h", "g", "retry")
          ]
        )

      BridgeStub.queue(bridge, "coder", BridgeStub.outcome("blocked", [BridgeStub.question()]))
      task = start!(grouped)
      BridgeStub.step(bridge)

      assert %{status: :await_human_supervision} = task = Board.get_task!(task.id)
      assert current_label(task) == "Help"
    end

    test "a capped arrow out of a human block is offered only while it has traversals left",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Helper", :custom)

      capped =
        workflow!(
          "Capped decision",
          [
            block("a", :agent, agent_role: :custom, label: "Helper", start: true),
            block("h", :human, label: "Check", x: 1),
            block("d", :column, column_status: :done, x: 2)
          ],
          [
            arrow("e1", "a", "h", "done"),
            arrow("again", "h", "a", "again", 1),
            arrow("ok", "h", "d", "ok")
          ]
        )

      task = start!(capped)
      BridgeStub.step(bridge)
      task = Board.get_task!(task.id)
      Board.decide_task!(task, decision(task, "again").id)
      BridgeStub.step(bridge)

      task = Board.get_task!(task.id)
      assert current_label(task) == "Check"
      graph = Workflows.graph!(capped.id)
      assert ["ok"] = Enum.map(Engine.decisions(task, graph), & &1.edge.condition)
    end

    test "a coder on another connector starts its own conversation, told the findings",
         %{bridge: bridge, connector: connector} do
      other = Connectors.create_connector!(%{name: "Other", provider: :claude_code})
      first = agent(connector, "Ada", :coder)
      second = agent(other, "Bea", :coder)
      team(connector, [:reviewer])

      handover =
        workflow!(
          "Two connectors",
          [
            block("a", :agent, employee_id: first.id, label: "Ada", start: true),
            block("r", :agent, agent_role: :reviewer, label: "Reviewer", x: 1),
            block("b", :agent, employee_id: second.id, label: "Bea", x: 2),
            block("d", :column, column_status: :done, x: 3)
          ],
          [
            arrow("e1", "a", "r", "done"),
            arrow("fix", "r", "b", "findings", 2),
            arrow("e2", "b", "r", "done", 3),
            arrow("e3", "r", "d", "clean")
          ]
        )

      BridgeStub.queue(bridge, "reviewer", BridgeStub.findings(1))
      BridgeStub.queue(bridge, "coder", BridgeStub.outcome())
      task = start!(handover)
      for _run <- 1..3, do: BridgeStub.step(bridge)

      assert [ada, _review, bea] = started_runs()
      assert ada["resume"] == nil
      assert bea["resume"] == nil
      assert bea["prompt"] =~ "Approved plan"
      assert bea["prompt"] =~ "fix round 1 of 2"
      assert bea["prompt"] =~ "Crashes on nil 1"

      assert %{code_session_connector_id: connector_id} = Board.get_task!(task.id)
      assert connector_id == other.id

      # Bea's conversation is hers: the next fix round on the same connector resumes it.
      BridgeStub.queue(bridge, "reviewer", BridgeStub.findings(1))
      for _run <- 1..2, do: BridgeStub.step(bridge)
      assert [_review, again] = started_runs()
      assert again["resume"]
    end

    test "a reviewer running again in a round replaces its own findings, keeps the others'",
         %{bridge: bridge, connector: connector} do
      team(connector, [:coder, :reviewer, :qa])

      twice =
        workflow!(
          "Review twice",
          [
            block("c", :agent, agent_role: :coder, label: "Coder", start: true),
            block("q", :agent, agent_role: :qa, label: "Docker reviewer", x: 1),
            block("r", :agent, agent_role: :reviewer, label: "Reviewer", x: 2),
            block("d", :column, column_status: :done, x: 3)
          ],
          [
            arrow("e1", "c", "q", "done"),
            arrow("e2", "q", "r"),
            arrow("loop", "r", "r", nil, 2),
            arrow("back", "r", "c", "findings", 1),
            arrow("e3", "r", "d", "clean")
          ]
        )

      BridgeStub.queue(bridge, "qa", BridgeStub.findings(1))
      for _pass <- 1..2, do: BridgeStub.queue(bridge, "reviewer", BridgeStub.findings(2))
      start!(twice)
      for _run <- 1..5, do: BridgeStub.step(bridge)

      assert ["coder", "qa", "reviewer", "reviewer", "coder"] = profiles(runs = started_runs())
      fix = List.last(runs)["prompt"]
      assert length(String.split(fix, "Crashes on nil 2")) == 2
      assert fix =~ "[qa] f1"
      assert fix =~ "[reviewer] f2"
    end

    test "a review loop drawn inside a group: findings go back to the coder, clean leaves the group",
         %{bridge: bridge, connector: connector} do
      team(connector, [:coder, :reviewer])

      grouped =
        workflow!(
          "Loop inside",
          [
            block("g", :group, label: "Build", start: true),
            block("c", :agent, agent_role: :coder, label: "Coder", group_id: "g", x: 1),
            block("r", :agent, agent_role: :reviewer, label: "Reviewer", group_id: "g", x: 2),
            block("h", :human, label: "Check", x: 3),
            block("d", :column, column_status: :done, x: 4)
          ],
          [
            arrow("inner", "c", "r", "done"),
            arrow("back", "r", "c", "findings", 2),
            arrow("out", "g", "h", "clean"),
            arrow("ok", "h", "d", "ok")
          ]
        )

      assert %{problem_count: 0} = Workflows.get_workflow!(grouped.id)
      for _round <- 1..3, do: BridgeStub.queue(bridge, "reviewer", BridgeStub.findings(1))
      task = start!(grouped)
      for _run <- 1..6, do: BridgeStub.step(bridge)

      runs = started_runs()
      assert ["coder", "reviewer", "coder", "reviewer", "coder", "reviewer"] = profiles(runs)
      assert Enum.at(runs, 4)["prompt"] =~ "fix round 2 of 2"

      # The fix rounds used up, the findings leave the group by its one arrow, attached.
      task = Board.get_task!(task.id)
      assert current_label(task) == "Check"
      assert %{status: :await_human_supervision, review_round: 2, findings: [_]} = task
    end

    test "entering a group at an inner block counts as a new run of the group",
         %{bridge: bridge, connector: connector} do
      team(connector, [:coder, :reviewer])

      grouped =
        workflow!(
          "Re-entered group",
          [
            block("g", :group, label: "Build", start: true),
            block("c", :agent, agent_role: :coder, label: "Coder", group_id: "g", x: 1),
            block("r", :agent, agent_role: :reviewer, label: "Reviewer", group_id: "g", x: 2),
            block("h", :human, label: "Check", x: 3)
          ],
          [
            arrow("inner", "c", "r", "done"),
            arrow("loop", "g", "g", nil, 2),
            arrow("out", "g", "h", "clean"),
            arrow("review", "h", "r", "review again")
          ]
        )

      task = start!(grouped)
      for _run <- 1..4, do: BridgeStub.step(bridge)
      assert ["coder", "reviewer", "coder", "reviewer"] = profiles(started_runs())
      task = Board.get_task!(task.id)
      assert current_label(task) == "Check"

      Board.decide_task!(task, decision(task, "review again").id)
      for _run <- 1..3, do: BridgeStub.step(bridge)
      assert ["reviewer", "coder", "reviewer"] = profiles(started_runs())
    end
  end
end
