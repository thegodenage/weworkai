defmodule WeworkaiWeb.BoardLiveTest do
  use WeworkaiWeb.ConnCase

  # Start failures are logged with their full detail.
  @moduletag :capture_log

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Weworkai.WorkflowFixtures

  alias Weworkai.Repo

  alias Weworkai.{Board, Organization}

  test "creates a task into the backlog", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tasks/new")

    assert view
           |> form("#task-form", form: %{title: "  "})
           |> render_submit() =~ "is required"

    view
    |> form("#task-form", form: %{title: "Write spec", description: "First draft"})
    |> render_submit()

    assert_patch(view, ~p"/")
    assert has_element?(view, "#column-backlog article", "Write spec")
    refute has_element?(view, "#task-form")
  end

  test "moves a task to another column", %{conn: conn} do
    task = Board.create_task!(%{title: "Ship it"})
    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "move", %{"task_id" => task.id, "status" => "in_progress"})

    assert has_element?(view, "#column-in_progress article", "Ship it")
    refute has_element?(view, "#column-backlog article", "Ship it")
  end

  test "search and filters narrow the board; clearing brings every card back", %{conn: conn} do
    Board.create_task!(%{title: "Write spec", description: "First draft"})
    lean = Weworkai.Workflows.create_workflow!("Lean")
    login = Board.create_task!(%{title: "Fix login", workflow_id: lean.id})
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("#board-filters", filter: %{q: "draft"}) |> render_change()
    assert has_element?(view, "#column-backlog article", "Write spec")
    refute has_element?(view, "#column-backlog article", "Fix login")

    view |> form("#board-filters", filter: %{q: "", workflow: lean.id}) |> render_change()
    assert has_element?(view, "#column-backlog article", "Fix login")
    refute has_element?(view, "#column-backlog article", "Write spec")

    # A card the filters hide stays hidden when the workflow moves its task.
    view
    |> form("#board-filters", filter: %{workflow: "", assignee: "none", q: "spec"})
    |> render_change()

    Board.advance_task!(login, %{status: :in_progress})
    refute has_element?(view, "#column-in_progress article", "Fix login")
    assert has_element?(view, "#column-in_progress-empty", "No matching tasks")

    view |> element("#board-filters-clear") |> render_click()
    assert has_element?(view, "#column-backlog article", "Write spec")
    assert has_element?(view, "#column-in_progress article", "Fix login")
  end

  test "a task whose workflow has problems stays put, saying why", %{conn: conn} do
    {:ok, draft} = Weworkai.Workflows.create_workflow("Half drawn", nil, %{empty: true})
    task = Board.create_task!(%{title: "Stay put", workflow_id: draft.id})
    {:ok, view, _html} = live(conn, ~p"/")

    assert render_hook(view, "move", %{"task_id" => task.id, "status" => "todo"}) =~
             "The workflow “Half drawn” has a problem to fix in its editor"

    assert has_element?(view, "#column-backlog article", "Stay put")
  end

  test "rejects a move to an unknown status", %{conn: conn} do
    task = Board.create_task!(%{title: "Stay put"})
    {:ok, view, _html} = live(conn, ~p"/")

    assert render_hook(view, "move", %{"task_id" => task.id, "status" => "nowhere"}) =~
             "Could not move the task."

    assert has_element?(view, "#column-backlog article", "Stay put")
  end

  test "clicking a card opens its drawer, where status can change", %{conn: conn} do
    task = Board.create_task!(%{title: "Inspect me", description: "Line one\nLine two"})
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#column-backlog a", "Inspect me") |> render_click()

    assert_patch(view, ~p"/tasks/#{task.id}/edit")
    assert has_element?(view, "#task-drawer", "Line two")

    view
    |> form("#task-drawer-status", %{"task_id" => task.id, "status" => "done"})
    |> render_change()

    assert has_element?(view, "#column-done article", "Inspect me")
    assert has_element?(view, "#task-drawer option[selected][value=done]")
  end

  test "a task without code changes can't be dragged into review", %{conn: conn} do
    task = Board.create_task!(%{title: "Not coded"})
    {:ok, view, _html} = live(conn, ~p"/")

    assert render_hook(view, "move", %{"task_id" => task.id, "status" => "review"}) =~
             "Nothing to review yet: no code changes"

    assert has_element?(view, "#column-backlog article", "Not coded")
    refute has_element?(view, "#column-review article", "Not coded")
  end

  test "the workflow assigns the task: the drawer only shows who works on it", %{conn: conn} do
    ada = Organization.create_employee!(%{kind: :human, name: "Ada", role: "Engineer"})
    {:ok, view, _html} = live(conn, ~p"/tasks/new")
    refute has_element?(view, "#task-form [name*=assignee]")

    view
    |> form("#task-form", form: %{title: "Review spec"})
    |> render_submit()

    task = hd(Board.list_tasks!())
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}/edit")
    assert has_element?(view, "#task-drawer-assignee", "Nobody yet")
    refute has_element?(view, "#task-drawer [name=assignee_id]")

    Board.advance_task!(task, %{assignee_id: ada.id})
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}/edit")
    assert has_element?(view, "#task-drawer-assignee span[title=Ada]")
    assert has_element?(view, "#column-backlog article span[title=Ada]")
  end

  test "removing an employee unassigns their tasks" do
    ada = Organization.create_employee!(%{kind: :human, name: "Ada", role: "Engineer"})

    task =
      %{title: "Orphan"} |> Board.create_task!() |> Board.advance_task!(%{assignee_id: ada.id})

    Organization.destroy_employee!(ada)

    assert {:ok, %{assignee_id: nil}} = Board.get_task(task.id)
  end

  test "edits title and markdown description from the drawer", %{conn: conn} do
    task = Board.create_task!(%{title: "Draft"})
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}/edit")

    view
    |> form("#task-drawer-title-form", form: %{title: "Final"})
    |> render_change()

    view
    |> form("#task-drawer-description-form", form: %{description: "**bold** <script>x</script>"})
    |> render_change()

    assert has_element?(view, "#column-backlog article", "Final")
    assert has_element?(view, "#task-drawer-description-preview strong", "bold")
    refute has_element?(view, "#task-drawer-description-preview script")

    assert {:ok, %{title: "Final", description: "**bold** <script>x</script>"}} =
             Board.get_task(task.id)
  end

  test "blank title is rejected and not saved", %{conn: conn} do
    task = Board.create_task!(%{title: "Keep me"})
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}/edit")

    assert view
           |> form("#task-drawer-title-form", form: %{title: " "})
           |> render_change() =~ "is required"

    assert {:ok, %{title: "Keep me"}} = Board.get_task(task.id)
  end

  test "deletes a task from the drawer", %{conn: conn} do
    task = Board.create_task!(%{title: "Doomed"})
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}/edit")

    view |> element("#task-drawer-delete") |> render_click()

    assert_patch(view, ~p"/")
    refute has_element?(view, "#column-backlog article", "Doomed")
    refute has_element?(view, "#flash-error")
    assert {:error, _} = Board.get_task(task.id)
  end

  test "a task deleted elsewhere leaves every open board", %{conn: conn} do
    task = Board.create_task!(%{title: "Doomed elsewhere"})
    {:ok, board, _html} = live(conn, ~p"/")
    {:ok, drawer, _html} = live(conn, ~p"/tasks/#{task.id}/edit")

    Board.destroy_task!(task)

    refute has_element?(board, "#column-backlog article", "Doomed elsewhere")
    assert_patch(drawer, ~p"/")
    refute has_element?(drawer, "#task-drawer")
    assert has_element?(drawer, "#flash-error", "This task was deleted.")
  end

  test "unknown task id redirects to the board with a flash", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/", flash: %{"error" => "Task not found."}}}} =
             live(conn, ~p"/tasks/#{Ash.UUID.generate()}")
  end

  test "creates a task with a repository and edits it in the drawer", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tasks/new")

    view
    |> form("#task-form", form: %{title: "Plan it", repository: "~/Projects/app"})
    |> render_submit()

    [task] = Board.list_tasks!()
    assert task.repository == "~/Projects/app"

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}/edit")

    view
    |> form("#task-drawer-repository-form", form: %{repository: "~/Projects/other"})
    |> render_change()

    assert has_element?(view, "#task-drawer-repository-input[value='~/Projects/other']")
    assert Board.get_task!(task.id).repository == "~/Projects/other"
  end

  test "the new task form browses the bridge's folders", %{conn: conn} do
    Weworkai.BridgeStub.start()
    {:ok, view, _html} = live(conn, ~p"/tasks/new")
    Req.Test.allow(Weworkai.Connectors.ClaudeBridge, self(), view.pid)

    view |> element("#task-form-repository") |> render_hook("browse", %{"path" => "~/Projects"})
    assert has_element?(view, "#task-form-repository-folders", "app")
    assert has_element?(view, "#task-form-repository-folders [data-choose='~/Projects/app']")

    view |> element("#task-form-repository-up") |> render_click()
    assert has_element?(view, "#task-form-repository-folders", "Projects")
    refute has_element?(view, "#task-form-repository-up")

    view |> element("#task-form-repository") |> render_hook("close", %{})
    refute has_element?(view, "#task-form-repository-panel")
  end

  test "a folder the bridge can't list falls back to the allowed ones", %{conn: conn} do
    Weworkai.BridgeStub.start()
    {:ok, view, _html} = live(conn, ~p"/tasks/new")
    Req.Test.allow(Weworkai.Connectors.ClaudeBridge, self(), view.pid)

    view |> element("#task-form-repository") |> render_hook("browse", %{"path" => "/nope"})
    assert has_element?(view, "#task-form-repository-error", "/nope is not a folder")
    assert has_element?(view, "#task-form-repository-folders", "Projects")
  end

  test "the new task form starts in ~/Projects", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tasks/new")

    assert has_element?(view, "#task-form input[name='form[repository]'][value='~/Projects']")
  end

  describe "remembered repository and workflow" do
    test "a new task starts from the ones the browser remembers", %{conn: conn} do
      lean = Weworkai.Workflows.create_workflow!("Lean")

      {:ok, view, _html} =
        conn
        |> put_connect_params(%{
          "task_defaults" => %{"repository" => "~/Projects/app", "workflow_id" => lean.id}
        })
        |> live(~p"/tasks/new")

      assert has_element?(
               view,
               "#task-form input[name='form[repository]'][value='~/Projects/app']"
             )

      assert has_element?(
               view,
               "#task-form select[name='form[workflow_id]'] option[selected][value='#{lean.id}']"
             )
    end

    test "a remembered workflow that no longer exists falls back to the default", %{conn: conn} do
      default = Weworkai.Workflows.default_workflow!()

      {:ok, view, _html} =
        conn
        |> put_connect_params(%{"task_defaults" => %{"workflow_id" => Ash.UUID.generate()}})
        |> live(~p"/tasks/new")

      assert has_element?(
               view,
               "#task-form select[name='form[workflow_id]'] option[selected][value='#{default.id}']"
             )

      assert has_element?(view, "#task-form input[name='form[repository]'][value='~/Projects']")
    end

    test "creating a task remembers its repository and workflow for the next one", %{conn: conn} do
      lean = Weworkai.Workflows.create_workflow!("Lean")
      lean_id = lean.id
      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      view
      |> form("#task-form",
        form: %{title: "First", repository: "~/Projects/app", workflow_id: lean.id}
      )
      |> render_submit()

      assert_push_event(view, "remember-task-defaults", %{
        "repository" => "~/Projects/app",
        "workflow_id" => ^lean_id
      })

      render_patch(view, ~p"/tasks/new")

      assert has_element?(
               view,
               "#task-form input[name='form[repository]'][value='~/Projects/app']"
             )

      assert has_element?(
               view,
               "#task-form select[name='form[workflow_id]'] option[selected][value='#{lean.id}']"
             )
    end
  end

  defp unconfigured_planner do
    connector =
      Weworkai.Connectors.create_connector!(%{name: "Claude", provider: :claude_code})

    Organization.create_employee!(%{
      kind: :agent,
      name: "E2E Planner",
      agent_role: :planner,
      connector_id: connector.id
    })
  end

  test "an agent without a model cannot take a task; the card stays put", %{conn: conn} do
    unconfigured_planner()
    task = Board.create_task!(%{title: "Nowhere"})
    {:ok, view, _html} = live(conn, ~p"/")

    assert render_hook(view, "move", %{"task_id" => task.id, "status" => "todo"}) =~
             "Planner can&#39;t run: E2E Planner has no model yet. Configure it on the Employees page."

    assert has_element?(view, "#column-backlog article", "Nowhere")
    assert Board.get_task!(task.id).status == :backlog
  end

  test "the drawer's Continue names what the agent lacks, and can mark the task done",
       %{conn: conn} do
    planner = unconfigured_planner()
    task = Board.create_task!(%{title: "Failed"})
    Board.advance_task!(task, %{status: :await_human_supervision, stage: :planning})
    failed_job(task, planner)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}/edit")

    assert has_element?(view, "#task-drawer-continue", "Planner")
    # Reviewer blocks are offered once the task has code.
    refute has_element?(view, "#task-drawer-continue-#{block_id(task, "Reviewer")}")

    assert view |> element("#task-drawer-continue") |> render_click() =~
             "Planner can&#39;t run: E2E Planner has no model yet. Configure it on the Employees page."

    assert Board.get_task!(task.id).status == :await_human_supervision

    view |> element("#task-drawer-continue-done") |> render_click()
    assert has_element?(view, "#column-done article", "Failed")
  end

  defp failed_job(task, agent_employee) do
    job =
      Weworkai.Scheduling.create_job!(%{
        task_id: task.id,
        agent_id: agent_employee.agent_id,
        stage: :planning,
        folder: task.repository,
        prompt: "Plan"
      })

    Repo.update_all(from(j in "jobs", where: j.id == type(^job.id, Ecto.UUID)),
      set: [status: "failed"]
    )
  end

  test "a task the workflow changes moves on the board, with its stage", %{conn: conn} do
    task = Board.create_task!(%{title: "Agent work"})
    {:ok, view, _html} = live(conn, ~p"/")

    Board.advance_task!(task, %{status: :in_progress, stage: :code_review})

    assert has_element?(view, "#column-in_progress article [data-stage=code_review]")
    refute has_element?(view, "#column-backlog article", "Agent work")
    assert has_element?(view, "section[data-status=in_progress] header", "1")
  end

  test "the header links to the column of tasks waiting for a human, while there are some",
       %{conn: conn} do
    task = Board.create_task!(%{title: "Your turn"})
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#board-needs-you")

    Board.advance_task!(task, %{status: :await_human_supervision, stage: :planning})

    assert has_element?(
             view,
             "#board-needs-you[href='#board-column-await_human_supervision']",
             "1 task"
           )

    assert has_element?(view, "#board-column-await_human_supervision")
  end

  test "each lane counts its cards; a card waiting for a human carries the amber rule",
       %{conn: conn} do
    task = Board.create_task!(%{title: "Your turn"})
    Board.advance_task!(task, %{status: :await_human_supervision, stage: :planning})
    other = Board.create_task!(%{title: "Not yet"})
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#board-column-backlog-count", "[01]")
    assert has_element?(view, "#board-column-done-count", "[00]")
    assert has_element?(view, "article[data-task-id='#{task.id}'].tone-amber")
    refute has_element?(view, "article[data-task-id='#{other.id}'][class*='tone-']")

    view |> form("#board-filters", filter: %{q: "nothing like it"}) |> render_change()
    assert has_element?(view, "#board-column-backlog-count", "[00]")
  end

  test "a card waiting for a human is marked and opens the task view", %{conn: conn} do
    task = Board.create_task!(%{title: "Your turn"})
    Board.advance_task!(task, %{status: :await_human_supervision, stage: :planning})
    other = Board.create_task!(%{title: "Not yet"})
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#needs-you-#{task.id}")
    refute has_element?(view, "#needs-you-#{other.id}")
    assert has_element?(view, "#task-link-#{other.id}[data-phx-link=patch]")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#task-link-#{task.id}") |> render_click()

    assert to == ~p"/tasks/#{task.id}"
  end

  test "the drawer links to the task view", %{conn: conn} do
    task = Board.create_task!(%{title: "Drawer"})
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}/edit")

    assert has_element?(view, "#task-drawer-open[href='/tasks/#{task.id}']")
  end

  test "files picked for a new task are attached when it is created", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tasks/new")

    view
    |> file_input("#task-form", :attachments, [
      %{name: "spec.md", content: "# Spec", type: "text/markdown"}
    ])
    |> render_upload("spec.md")

    view |> form("#task-form", form: %{title: "With a spec"}) |> render_submit()

    [task] = Board.list_tasks!()
    assert [%{name: "spec.md", size: 6}] = Board.list_attachments!(task.id)
  end

  test "the drawer attaches a file once uploaded, shows it and removes it", %{conn: conn} do
    task = Board.create_task!(%{title: "Needs a mockup"})
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}/edit")

    view
    |> file_input("#task-drawer-attachments-form", :attachments, [
      %{name: "mock up.png", content: "png", type: "image/png"}
    ])
    |> render_upload("mock up.png")

    assert [%{id: id, name: "mock up.png"}] = Board.list_attachments!(task.id)
    assert has_element?(view, "#attachment-#{id} img[src='/attachments/#{id}']")
    assert has_element?(view, "#download-attachment-#{id}[href='/attachments/#{id}']")

    view |> element("#remove-attachment-#{id}") |> render_click()

    assert Board.list_attachments!(task.id) == []
    refute has_element?(view, "#attachment-#{id}")
  end

  describe "agent activity" do
    alias Weworkai.{Agents, BridgeStub, Connectors}
    alias Weworkai.Scheduling.Scheduler

    test "a card spins while an agent works on its task, also on a question",
         %{conn: conn} do
      bridge = BridgeStub.start()
      connector = Connectors.create_connector!(%{name: "Claude", provider: :claude_code})

      planner =
        Organization.create_employee!(%{
          kind: :agent,
          name: "Planner",
          agent_role: :planner,
          connector_id: connector.id
        })

      # Skips :configure, whose check would ask the bridge for its model list.
      planner.agent_id
      |> Agents.get_agent!()
      |> Ash.Changeset.for_update(:assign_role, %{role: :planner})
      |> Ash.Changeset.force_change_attributes(%{model: "claude-opus-5-5"})
      |> Ash.update!()

      task = Board.create_task!(%{title: "Plan me"})
      {:ok, view, _html} = live(conn, ~p"/")
      working = "#task-#{task.id}-working"
      refute has_element?(view, working)

      Board.move_task!(task, :todo)
      assert has_element?(view, "#{working}[data-state=queued][data-stage=planning]")

      Scheduler.dispatch_due()
      assert has_element?(view, "#{working}[data-state=running][data-stage=planning]")

      assert has_element?(
               view,
               "article[data-task-id='#{task.id}'][data-working=running].tone-accent"
             )

      assert has_element?(view, "#{working}-elapsed[data-since]")
      assert has_element?(view, "#board-column-in_progress-working", "1 working")

      BridgeStub.step(bridge)
      refute has_element?(view, working)
      assert has_element?(view, "#needs-you-#{task.id}")

      # A question leaves the task as it is: only its job's broadcast updates the card.
      Board.ask_question!(task.id, "Why?")
      assert has_element?(view, "#{working}[data-state=queued][data-stage=ask]")

      Scheduler.dispatch_due()
      assert has_element?(view, "#{working}[data-state=running][data-stage=ask]")

      BridgeStub.step(bridge)
      refute has_element?(view, working)
    end
  end

  describe "workflows" do
    test "a new task runs the default workflow unless the form picks another", %{conn: conn} do
      default = Weworkai.Workflows.default_workflow!()
      lean = Weworkai.Workflows.create_workflow!("Lean")
      {:ok, view, _html} = live(conn, ~p"/tasks/new")

      assert has_element?(
               view,
               "#task-form select[name='form[workflow_id]'] option[selected]",
               default.name
             )

      view
      |> form("#task-form", form: %{title: "Lean one", workflow_id: lean.id})
      |> render_submit()

      assert [%{workflow_id: workflow_id}] =
               Board.list_tasks!(query: [filter: [title: "Lean one"]])

      assert workflow_id == lean.id
    end

    test "the drawer switches the workflow, which starts the task over", %{conn: conn} do
      task = Board.create_task!(%{title: "Switch me"})
      Board.advance_task!(task, %{current_node_id: block_id(task, "Coder")})
      lean = Weworkai.Workflows.create_workflow!("Lean")
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}/edit")

      assert has_element?(view, "#task-drawer-block", "Coder")
      assert has_element?(view, "#task-#{task.id}-block", "Coder")
      assert has_element?(view, "#task-drawer-workflow[data-confirm*='starts “Switch me” over']")

      view |> form("#task-drawer-workflow-form", form: %{workflow_id: lean.id}) |> render_change()

      assert %{workflow_id: workflow_id, current_node_id: nil} = Board.get_task!(task.id)
      assert workflow_id == lean.id
      refute has_element?(view, "#task-drawer-block")
      refute has_element?(view, "#task-drawer-workflow[data-confirm]")
    end
  end
end
