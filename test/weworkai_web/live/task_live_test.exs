defmodule WeworkaiWeb.TaskLiveTest do
  use WeworkaiWeb.ConnCase, async: false

  # Start failures are logged with their full detail.
  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Weworkai.WorkflowFixtures

  alias Weworkai.{Agents, Board, BridgeStub, Connectors, Notifications, Organization}
  alias Weworkai.Connectors.ClaudeBridge

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

  defp planned_task(%{bridge: bridge, connector: connector}) do
    agent(connector, "Planner", :planner)

    task =
      Board.create_task!(%{
        title: "Greet users",
        repository: "/repos/app"
      })

    Board.move_task!(task, :todo)
    BridgeStub.step(bridge)
    Board.get_task!(task.id)
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    Req.Test.allow(ClaudeBridge, self(), view.pid)
    view
  end

  test "the header totals what the task's runs used; each run shows its own",
       %{conn: conn} = context do
    task = planned_task(context)
    view = open(conn, ~p"/tasks/#{task.id}?tab=runs")

    assert has_element?(view, "#task-usage", "4.6k tok · $0.0525")
    assert has_element?(view, "#runs [id$=-usage]", "4.6k tok · $0.0525")
  end

  test "sets the task's budget in the header; the meter shows spend against it",
       %{conn: conn} = context do
    task = planned_task(context)
    view = open(conn, ~p"/tasks/#{task.id}")
    refute has_element?(view, "#task-budget-meter")

    view |> element("#task-budget-edit") |> render_click()
    view |> form("#task-budget-form", budget: %{budget_usd: "0"}) |> render_submit()
    assert has_element?(view, "#task-budget-form")

    view |> form("#task-budget-form", budget: %{budget_usd: "0.06"}) |> render_submit()
    assert has_element?(view, "#task-budget-meter[data-mark=warning]", "$0.0525 / $0.0600")
    assert has_element?(view, "#task-budget-meter", "88%")
  end

  test "edits the repository from the header", %{conn: conn} = context do
    task = planned_task(context)
    view = open(conn, ~p"/tasks/#{task.id}")

    view |> element("#task-repository-edit") |> render_click()
    view |> element("#task-repository-picker") |> render_hook("browse", %{"path" => "~/Projects"})
    assert has_element?(view, "#task-repository-picker-folders", "app")

    view
    |> form("#task-repository-form", form: %{repository: "~/Projects/app"})
    |> render_submit()

    refute has_element?(view, "#task-repository-form")
    assert has_element?(view, "#task-repository", "~/Projects/app")
    assert Board.get_task!(task.id).repository == "~/Projects/app"
  end

  test "renders the plan with merge-request style diffs", %{conn: conn} = context do
    task = planned_task(context)
    view = open(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#task-title", "Greet users")
    assert has_element?(view, "#task-needs-you")
    assert has_element?(view, "#task-stage[data-stage=planning]")
    assert has_element?(view, "#task-repository", "/repos/app")
    assert has_element?(view, "#plan-summary", "Add a greeting helper.")
    assert has_element?(view, "#step-s1", "Add the Greeting module")
    assert has_element?(view, "#step-s2", "Test it")
    assert has_element?(view, "#diff-s1-0", "lib/greeting.ex")

    assert has_element?(
             view,
             "#diff-s1-0 tr.diff-addition[data-ref='lib/greeting.ex:1']",
             "defmodule Greeting, do: nil"
           )

    assert has_element?(view, "#diff-s1-0 .diff-hunk", "@@ -0,0 +1 @@")
    assert has_element?(view, "#plan-decisions-callout")
    assert has_element?(view, "#tab-questions", "1")
  end

  test "comments on selected steps and lines; the planner's revision arrives live",
       %{conn: conn, bridge: bridge} = context do
    task = planned_task(context)
    view = open(conn, ~p"/tasks/#{task.id}")

    view |> element("#step-s2-select") |> render_click()
    view |> element("#diff-s1-0-line-0-0") |> render_click()

    assert has_element?(view, "#step-s2[data-selected]")
    assert has_element?(view, "#chip-step-s2", "Test it")
    assert has_element?(view, "#comment-references button", "lib/greeting.ex:1")
    assert has_element?(view, "#diff-s1-0-line-0-0.diff-selected")

    view |> form("#comment-form", comment: %{body: "Use gettext"}) |> render_submit()

    assert has_element?(view, "#agent-working")
    assert has_element?(view, "#task-working[data-stage=planning]")
    assert has_element?(view, "#review-closed", "revising the plan")
    refute has_element?(view, "#comment-form")

    assert [_plan, %{kind: :comment, step_ids: ["s2"], body: body}] =
             Board.list_messages!(task.id)

    assert body == "Use gettext\n\nLines:\n- `lib/greeting.ex:1`"

    BridgeStub.step(bridge)
    # The toast queues behind the task updates the run made, each a reload: a render returns
    # once the view handled them all, so its push is already in this process's mailbox.
    render(view)

    assert_push_event(view, "notification", %{
      kind: :plan_ready,
      icon: "hero-map-micro",
      tone: "tone-violet"
    })

    assert has_element?(view, "#comment-form")
    refute has_element?(view, "#agent-working")
    refute has_element?(view, "#task-working")
    refute has_element?(view, "#chip-step-s2")
  end

  test "a blank comment is not sent", %{conn: conn} = context do
    task = planned_task(context)
    view = open(conn, ~p"/tasks/#{task.id}")

    assert view |> form("#comment-form", comment: %{body: "  "}) |> render_submit() =~
             "Write what the planner should change."

    assert Board.get_task!(task.id).status == :await_human_supervision
  end

  test "answers the planner's questions", %{conn: conn} = context do
    task = planned_task(context)
    view = open(conn, ~p"/tasks/#{task.id}?tab=questions")

    assert has_element?(view, "#question-q1", "Localize the greeting?")
    assert has_element?(view, "#question-q1-option-1", "Gettext")

    assert view |> form("#answers-form", answers: %{q1: %{other: " "}}) |> render_submit() =~
             "Answer every question before sending."

    view
    |> form("#answers-form", answers: %{q1: %{choice: "Gettext"}})
    |> render_submit()

    assert Board.get_task!(task.id).status == :in_progress
    assert [_plan, %{kind: :answer, body: body}] = Board.list_messages!(task.id)
    assert body =~ "→ Gettext"
  end

  test "a written answer wins over a picked option, for the coder too",
       %{conn: conn, bridge: bridge, connector: connector} = context do
    task = planned_task(context)
    coder = agent(connector, "Coder", :coder)
    BridgeStub.queue(bridge, "coder", BridgeStub.outcome("blocked", [BridgeStub.question()]))
    Board.approve_plan!(task, coder.id)
    BridgeStub.step(bridge)

    view = open(conn, ~p"/tasks/#{task.id}?tab=questions")
    assert has_element?(view, "#questions-panel", "The coder asks")

    view
    |> form("#answers-form", answers: %{q1: %{choice: "No", other: "Only English for now"}})
    |> render_submit()

    assert %{status: :in_progress, stage: :coding} = Board.get_task!(task.id)
    assert List.last(Board.list_messages!(task.id)).body =~ "→ Only English for now"
  end

  test "hands the plan to the chosen coder", %{conn: conn, connector: connector} = context do
    task = planned_task(context)
    agent(connector, "Ada", :coder)
    grace = agent(connector, "Grace", :coder)
    view = open(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#approve-coder option", "Grace")

    view |> form("#approve-form", coder_id: grace.id) |> render_submit()

    assert %{status: :todo, assignee_id: assignee_id, plan_approved_at: approved} =
             Board.get_task!(task.id)

    assert assignee_id == grace.id
    assert approved
    refute has_element?(view, "#approve-plan")
    assert has_element?(view, "#task-branch", "weworkai/")
    assert has_element?(view, "#review-closed", "the plan is with the coder")
    assert has_element?(view, "#flash-info", "Plan approved.")

    # Once the coder takes it, the approval's flash is out of date.
    Weworkai.Scheduling.Scheduler.dispatch_due()
    assert has_element?(view, "#task-status[data-status=in_progress]")
    refute has_element?(view, "#flash-info")
  end

  test "with one coder there is nothing to pick: the plan goes on to it",
       %{conn: conn, connector: connector} = context do
    task = planned_task(context)
    ada = agent(connector, "Ada", :coder)
    view = open(conn, ~p"/tasks/#{task.id}")
    refute has_element?(view, "#approve-coder")

    view |> form("#approve-form") |> render_submit()

    assert %{status: :todo, assignee_id: assignee_id, pinned_coder_id: nil} =
             Board.get_task!(task.id)

    assert assignee_id == ada.id
    assert has_element?(view, "#flash-info", "Plan approved. Ada starts coding.")
  end

  test "without a coder agent the plan cannot be approved", %{conn: conn} = context do
    task = planned_task(context)
    view = open(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#approve-plan[disabled]")
    assert has_element?(view, "#no-coder")
  end

  test "only coders that can run are offered", %{conn: conn, connector: connector} = context do
    task = planned_task(context)
    agent(connector, "Ada", :coder)
    agent(connector, "Grace", :coder)
    # No model yet.
    Organization.create_employee!(%{
      kind: :agent,
      name: "Unconfigured",
      agent_role: :coder,
      connector_id: connector.id
    })

    view = open(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#approve-coder option", "Grace")
    refute has_element?(view, "#approve-coder option", "Unconfigured")
  end

  test "renders the reviewers' findings with the fix round", %{conn: conn} do
    task = Board.create_task!(%{title: "Reviewed"})

    Board.advance_task!(task, %{
      status: :in_progress,
      stage: :coding,
      review_round: 2,
      findings: [
        %{
          source: :reviewer,
          id: "f1",
          severity: :high,
          title: "Crashes on nil",
          path: "lib/greeting.ex",
          line: 2,
          details: "`hello(nil)` raises.",
          reproduction: "Greeting.hello(nil)",
          evidence: "** (ArgumentError)"
        },
        %{source: :qa, id: "f1", severity: :low, title: "Missing doc"}
      ]
    })

    view = open(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#tab-findings[aria-current=page]")
    assert has_element?(view, "#review-round", "Fix round 2 of 3")
    assert has_element?(view, "#finding-reviewer-f1", "Crashes on nil")
    assert has_element?(view, "#finding-reviewer-f1", "Code reviewer")
    assert has_element?(view, "#finding-reviewer-f1 code", "lib/greeting.ex:2")
    assert has_element?(view, "#finding-reviewer-f1 .markdown code", "hello(nil)")
    assert has_element?(view, "#finding-reviewer-f1 pre", "** (ArgumentError)")
    assert has_element?(view, "#finding-qa-f1", "Docker reviewer")
  end

  test "findings of two runs of one reviewer (a loop) keep unique ids", %{conn: conn} do
    task = Board.create_task!(%{title: "Reviewed twice"})
    finding = %{source: :reviewer, id: "f1", severity: :high, title: "Crashes on nil"}

    Board.advance_task!(task, %{
      status: :await_human_supervision,
      findings: [finding, %{finding | title: "Crashes on nil, again"}]
    })

    view = open(conn, ~p"/tasks/#{task.id}?tab=findings")
    document = view |> render() |> LazyHTML.from_fragment()
    ids = document |> LazyHTML.query("#findings-panel article") |> LazyHTML.attribute("id")

    assert ids == ["finding-reviewer-f1", "finding-reviewer-f1-2"]
    assert has_element?(view, "#finding-reviewer-f1-2", "Crashes on nil, again")
  end

  test "activity lists the conversation; runs link to their logs",
       %{conn: conn} = context do
    task = planned_task(context)
    view = open(conn, ~p"/tasks/#{task.id}?tab=activity")

    assert has_element?(view, "#messages li[id^=messages-]", "Add a greeting helper.")
    assert has_element?(view, "#messages li", "Planner")

    view |> element("#tab-runs") |> render_click()

    assert has_element?(view, "#tab-runs[aria-current=page]")
    refute has_element?(view, "#tab-activity[aria-current=page]")

    assert has_element?(view, "#runs li[id^=runs-]", "Planning")
    assert has_element?(view, "#runs a[href^='/dashboard/runs/']")
  end

  test "a workflow change shows up live, announced once by its toast", %{conn: conn} do
    task = Board.create_task!(%{title: "Watched"})
    view = open(conn, ~p"/tasks/#{task.id}")

    refute has_element?(view, "#task-needs-you")

    Board.advance_task!(task, %{status: :await_human_supervision, stage: :coding})
    Notifications.notify!(%{task_id: task.id, kind: :needs_answers, title: "Coder needs answers"})

    assert has_element?(view, "#task-needs-you")
    assert_push_event(view, "notification", %{title: "Coder needs answers"})
    refute has_element?(view, "#flash-info")
  end

  test "the default tab follows the plan's arrival, a chosen tab stays", %{conn: conn} do
    task = Board.create_task!(%{title: "Planned later"})
    default = open(conn, ~p"/tasks/#{task.id}")
    chosen = open(conn, ~p"/tasks/#{task.id}?tab=activity")

    assert has_element?(default, "#activity-panel")

    Board.advance_task!(task, %{plan: %{summary: "Do it.", steps: []}})

    assert has_element?(default, "#plan-summary")
    assert has_element?(chosen, "#activity-panel")
  end

  # The default workflow saved again, its planner block under `planner_id` when given.
  defp resave_default!(planner_id \\ nil) do
    workflow = Weworkai.Workflows.default_workflow!()
    params = Weworkai.Workflows.params(Weworkai.Workflows.graph!(workflow.id))
    planner = Enum.find(params.nodes, &(&1.label == "Planner")).id
    swap = &if(&1 == planner and planner_id, do: planner_id, else: &1)

    params = %{
      nodes: Enum.map(params.nodes, &%{&1 | id: swap.(&1.id)}),
      edges: Enum.map(params.edges, &%{&1 | from: swap.(&1.from), to: swap.(&1.to)})
    }

    {:ok, %{workflow: saved}} = Weworkai.Workflows.save_graph(workflow, params)
    saved
  end

  test "shows the version the task runs and moves it to a newer one on its block",
       %{conn: conn} = context do
    task = planned_task(context)
    view = open(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#task-workflow-version", "v1")
    refute has_element?(view, "#task-upgrade-workflow")

    resave_default!()
    view = open(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#task-upgrade-workflow", "Move to v2")

    view |> element("#task-upgrade-workflow") |> render_click()

    assert has_element?(view, "#task-workflow-version", "v2")
    refute has_element?(view, "#task-upgrade-workflow")
    assert %{workflow_version: 2} = Board.get_task!(task.id)

    resave_default!(Ecto.UUID.generate())
    view = open(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#task-newer-workflow", "v3 available")
    assert has_element?(view, "#task-newer-workflow-reason", "Its block is not in v3")
    assert has_element?(view, "#task-block", "Planner")
  end

  test "a deleted task sends the view back to the board", %{conn: conn} do
    task = Board.create_task!(%{title: "Short-lived"})
    view = open(conn, ~p"/tasks/#{task.id}")

    Board.destroy_task!(task)

    assert {"/", %{"error" => "This task was deleted."}} = assert_redirect(view)
  end

  describe "review" do
    defp coded_task(%{bridge: bridge, connector: connector} = context) do
      task = planned_task(context)
      coder = agent(connector, "Coder", :coder)
      agent(connector, "Reviewer", :reviewer)
      Board.approve_plan!(task, coder.id)
      BridgeStub.step(bridge)
      Board.get_task!(task.id)
    end

    test "shows the reviewers working, then the branch ready to merge, then done",
         %{conn: conn, bridge: bridge} = context do
      task = coded_task(context)
      view = open(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#task-status[data-status=review]")
      assert has_element?(view, "#agent-working", "The code reviewer is reading the change.")
      refute has_element?(view, "#ready-to-merge")
      refute has_element?(view, "#mark-done")

      BridgeStub.step(bridge)
      render(view)

      assert_push_event(view, "notification", %{kind: :ready_to_merge})
      refute has_element?(view, "#agent-working")
      assert has_element?(view, "#task-needs-you")
      assert has_element?(view, "#ready-to-merge-branch", task.worktree_branch)

      view |> element("#mark-done") |> render_click()

      assert Board.get_task!(task.id).status == :done
      assert has_element?(view, "#task-status[data-status=done]")
      refute has_element?(view, "#ready-to-merge")
    end

    test "the merger merges the branch from the gate, which then waits for the human",
         %{conn: conn, bridge: bridge, connector: connector} = context do
      task = coded_task(context)
      BridgeStub.step(bridge)

      view = open(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#merge-task[disabled]")

      agent(connector, "Merger", :merger)
      view = open(conn, ~p"/tasks/#{task.id}")
      refute has_element?(view, "#merge-task[disabled]")

      view |> form("#merge-form", %{branch: "main"}) |> render_submit()
      assert %{stage: :merging} = Board.get_task!(task.id)
      refute has_element?(view, "#merge-form")

      BridgeStub.step(bridge)
      render(view)

      assert has_element?(view, "#merged-into", "main")
      assert has_element?(view, "#mark-done")
      assert has_element?(view, "#merge-form")
    end

    test "open findings after the last fix round are pointed at", %{conn: conn} do
      task = Board.create_task!(%{title: "Rough"})

      task
      |> Ash.Changeset.for_update(:advance, %{
        status: :await_human_supervision,
        review_round: 3,
        findings: [%{source: :qa, id: "f1", severity: :low, title: "Missing doc"}]
      })
      |> Ash.Changeset.force_change_attributes(
        worktree_path: "/repos/app/.weworkai/worktrees/x",
        worktree_branch: "weworkai/x"
      )
      |> Ash.update!()

      view = open(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#ready-to-merge a", "1 finding is still open")
      assert has_element?(view, "#mark-done")

      render_async(view)
      assert has_element?(view, "#pow-findings-low", "1")
      assert has_element?(view, "#pow-changes-failed", "can't be read")
    end

    test "the ready branch comes with its proof of work: diff, reports, runs, spend",
         %{conn: conn, bridge: bridge} = context do
      task = coded_task(context)
      view = open(conn, ~p"/tasks/#{task.id}")
      refute has_element?(view, "#proof-of-work")

      BridgeStub.step(bridge)
      # The update is in the view's mailbox; rendering handles it and starts the diff read.
      render_async(view)

      assert has_element?(view, "#pow-files", "1")
      assert has_element?(view, "#pow-file-0", "lib/greeting.ex")
      assert has_element?(view, "#pow-lines", "+1")
      assert has_element?(view, "#pow-findings", "Clean")
      assert has_element?(view, "#pow-report-coder")
      assert has_element?(view, "#pow-report-reviewer", "Clean")
      assert has_element?(view, "#pow-stage-coding a[href^='/dashboard/runs/']")
      assert has_element?(view, "#pow-stage-code_review")
      assert has_element?(view, "#pow-budget", "no cap")
      assert has_element?(view, "#pow-span", "wall")

      view |> element("#mark-done") |> render_click()
      refute has_element?(view, "#proof-of-work")
    end
  end

  describe "continue" do
    test "a coded task that stalled continues to review from the menu",
         %{conn: conn, bridge: bridge, connector: connector} = context do
      task = planned_task(context)
      coder = agent(connector, "Coder", :coder)
      Board.approve_plan!(task, coder.id)
      Weworkai.Scheduling.Scheduler.dispatch_due()

      Board.move_task!(Board.get_task!(task.id), :backlog)
      view = open(conn, ~p"/tasks/#{task.id}")
      review = "#continue-task-#{block_id(task, "Reviewer")}"
      assert has_element?(view, "#continue-task", "Coder")
      assert has_element?(view, review, "Reviewer")

      reviewer =
        Organization.create_employee!(%{
          kind: :agent,
          name: "Reviewer",
          agent_role: :reviewer,
          connector_id: connector.id
        })

      assert view |> element(review) |> render_click() =~
               "Reviewer has no model yet. Configure it on the Employees page."

      set_model(reviewer, "claude-opus-5-5")
      view |> element(review) |> render_click()

      assert has_element?(view, "#task-status[data-status=review]")
      assert has_element?(view, "#agent-working", "The code reviewer is reading the change.")
      BridgeStub.step(bridge)
    end
  end

  describe "ask" do
    test "a question is answered in the thread without moving the task",
         %{conn: conn, bridge: bridge} = context do
      task = planned_task(context)
      view = open(conn, ~p"/tasks/#{task.id}?tab=ask")

      assert has_element?(view, "#ask-thread-empty")
      assert has_element?(view, "#ask-hint", "a copy of the planner's conversation")

      view |> form("#ask-form", ask: %{body: "Why two steps?"}) |> render_submit()

      assert has_element?(view, "#ask-thread li", "Why two steps?")
      assert has_element?(view, "#ask-pending")
      assert has_element?(view, "#tab-ask", "1")

      BridgeStub.step(bridge)
      render(view)

      assert_push_event(view, "notification", %{kind: :answer_ready})
      refute has_element?(view, "#ask-pending")
      assert has_element?(view, "#ask-thread li", "Stub answer to: Why two steps?")
      assert Board.get_task!(task.id).status == :await_human_supervision

      view |> element("#tab-activity") |> render_click()
      assert has_element?(view, "#messages li", "Stub answer to: Why two steps?")
    end

    test "the header spins while a question is answered",
         %{conn: conn, bridge: bridge} = context do
      task = planned_task(context)
      view = open(conn, ~p"/tasks/#{task.id}")
      refute has_element?(view, "#task-working")

      # Asked elsewhere: only the job's broadcast tells this page.
      Board.ask_question!(task.id, "Why two steps?")
      assert has_element?(view, "#task-working[data-state=queued][data-stage=ask]")
      refute has_element?(view, "#agent-working")

      Weworkai.Scheduling.Scheduler.dispatch_due()
      assert has_element?(view, "#task-working[data-state=running][data-stage=ask]")

      BridgeStub.step(bridge)
      refute has_element?(view, "#task-working")
    end

    test "a blank question is not sent", %{conn: conn} = context do
      task = planned_task(context)
      view = open(conn, ~p"/tasks/#{task.id}?tab=ask")

      assert view |> form("#ask-form", ask: %{body: "  "}) |> render_submit() =~
               "Write your question first."

      assert has_element?(view, "#ask-thread-empty")
    end

    test "without an agent that can answer, the form is disabled", %{conn: conn} do
      task = Board.create_task!(%{title: "Lonely"})
      view = open(conn, ~p"/tasks/#{task.id}?tab=ask")

      assert has_element?(view, "#ask-submit[disabled]")
      assert has_element?(view, "#ask-hint", "No agent can answer yet")
    end
  end

  defp set_model(employee, model) do
    agent = Agents.get_agent!(employee.agent_id)

    agent
    |> Ash.Changeset.for_update(:assign_role, %{role: agent.role})
    |> Ash.Changeset.force_change_attributes(%{model: model})
    |> Ash.update!()
  end

  test "a failed start reads plainly and continues once the agent is fixed",
       %{conn: conn, bridge: bridge, connector: connector} do
    planner = agent(connector, "Planner", :planner)
    task = Board.create_task!(%{title: "Retry me"})
    Board.move_task!(task, :todo)
    set_model(planner, nil)
    BridgeStub.step(bridge)

    view = open(conn, ~p"/tasks/#{task.id}?tab=activity")
    assert has_element?(view, "#messages", "The planner can't start: Planner has no model yet.")
    refute has_element?(view, "#messages", "Bread Crumbs")

    assert has_element?(view, "#continue-task", "Planner")
    assert view |> element("#continue-task") |> render_click() =~ "Planner has no model yet."
    assert Board.get_task!(task.id).status == :await_human_supervision

    set_model(planner, "claude-opus-5-5")
    assert view |> element("#continue-task") |> render_click() =~ "Continued."
    assert has_element?(view, "#messages", "Continued by you → Planner")
    # The new job is queued, so continuing again asks before stopping it.
    assert has_element?(view, "#continue-task[data-confirm]")

    Weworkai.Scheduling.Scheduler.dispatch_due()
    assert has_element?(view, "#task-status[data-status=in_progress]")
  end

  test "an error saved before readable errors still reads plainly", %{conn: conn} do
    task = Board.create_task!(%{title: "Old failure"})

    Board.create_message!(%{
      task_id: task.id,
      author: :agent,
      agent_role: :planner,
      kind: :system,
      body: """
      The agent could not be started:
      Bread Crumbs:
        > Error returned from: Weworkai.Agents.AgentRun.start

      Invalid Error

      * Invalid value provided for folder: ~/Projects/app is not a folder on this computer.

      Value: nil

        (ash 3.37.0) lib/ash/actions/create/create.ex:89: Ash.Actions.Create.run/4
      """
    })

    view = open(conn, ~p"/tasks/#{task.id}?tab=activity")

    assert has_element?(
             view,
             "#messages",
             "The agent could not be started: Invalid value provided for folder: ~/Projects/app is not a folder on this computer."
           )

    refute has_element?(view, "#messages", "Bread Crumbs")
    refute has_element?(view, "#messages", "ash 3.37.0")
  end

  describe "decisions" do
    test "a human block shows one button per arrow out; one takes the task on", %{conn: conn} do
      task = Board.create_task!(%{title: "Merged?", repository: "/repos/app"})

      task =
        Board.advance_task!(task, %{
          status: :await_human_supervision,
          current_node_id: block_id(task, "Approve")
        })

      view = open(conn, ~p"/tasks/#{task.id}")
      assert has_element?(view, "#task-block", "Approve")
      graph = Weworkai.Workflows.graph!(task.workflow_id)

      [accepted, continue] =
        for condition <- ["accepted", "continue"],
            do: Enum.find(graph.edges, &(&1.condition == condition))

      assert has_element?(view, "#decide-#{accepted.id}", "accepted")
      assert has_element?(view, "#decide-#{continue.id}", "continue")

      view
      |> form("#decision-form", %{comment: "  Ship it, then tidy the docs. "})
      |> render_change()

      view |> element("#decide-#{accepted.id}") |> render_click()

      assert has_element?(view, "#task-status[data-status=done]")
      refute has_element?(view, "#decide-#{continue.id}")

      assert [%{kind: :decision, body: "Decided: accepted\n\nShip it, then tidy the docs."}] =
               Board.list_messages!(task.id)
    end

    test "the plan approval replaces the approve plan block's own button",
         %{conn: conn} = context do
      task = planned_task(context)
      agent(context.connector, "Coder", :coder)
      view = open(conn, ~p"/tasks/#{task.id}")

      assert has_element?(view, "#approve-plan")
      refute has_element?(view, "[id^=decide-]")
    end
  end
end
