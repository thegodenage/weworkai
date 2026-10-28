defmodule WeworkaiWeb.BoardTagsLiveTest do
  use WeworkaiWeb.ConnCase

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias Weworkai.{Board, Recurring, Workflows}
  alias Weworkai.Recurring.Runner

  test "tags typed in the new task form show on the card and filter the board", %{conn: conn} do
    other = Board.create_task!(%{title: "Untagged"})
    {:ok, view, _html} = live(conn, ~p"/tasks/new")

    view
    |> form("#task-form", form: %{title: "Digest", tags: "gitlab, daily, GitLab"})
    |> render_submit()

    task = Enum.find(Board.list_tasks!(), &(&1.title == "Digest"))
    assert task.tags == ["gitlab", "daily"]
    assert has_element?(view, "#task-#{task.id}-tags [data-tag='gitlab']")
    refute has_element?(view, "#task-#{task.id}-cron-time")

    view |> form("#board-filters", filter: %{tag: "gitlab"}) |> render_change()
    assert has_element?(view, "#task-link-#{task.id}")
    refute has_element?(view, "#task-link-#{other.id}")
  end

  test "a cron's task arrives on the board tagged CRON, with its scheduled time", %{conn: conn} do
    # Its workflow refuses to start (no planner agent): the card still arrives, in backlog.
    cron =
      Recurring.create_cron!(%{
        name: "Morning digest",
        workflow_id: Workflows.default_workflow!().id,
        days: [1, 2, 3, 4, 5, 6, 7],
        at: ~T[09:00:00],
        timezone: "Europe/Warsaw"
      })

    {:ok, view, _html} = live(conn, ~p"/")
    :ok = Runner.start_due(DateTime.add(cron.next_run_at, 1, :minute))
    [task] = Board.list_tasks!()
    _ = render(view)

    assert has_element?(view, "#board-column-backlog #task-link-#{task.id}")
    assert has_element?(view, "#task-#{task.id}-tags [data-tag='CRON']")

    assert has_element?(
             view,
             "#task-#{task.id}-cron-time",
             Recurring.local_time(task.cron_run_at, "Europe/Warsaw")
           )

    {:ok, drawer, _html} = live(conn, ~p"/tasks/#{task.id}/edit")
    assert has_element?(drawer, "#task-drawer-cron", "Morning digest")

    drawer |> form("#task-drawer-tags-form", form: %{tags: "CRON, gitlab"}) |> render_change()
    assert Board.get_task!(task.id).tags == ["CRON", "gitlab"]
  end
end
