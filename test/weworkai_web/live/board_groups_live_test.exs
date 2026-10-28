defmodule WeworkaiWeb.BoardGroupsLiveTest do
  use WeworkaiWeb.ConnCase

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias Weworkai.{Board, Recurring, Workflows}
  alias Weworkai.Recurring.Runner

  defp stack(group, status), do: "##{status}_groups-#{group.id}-#{status}"

  defp grouped!(name, titles) do
    group = Board.create_task_group!(name)

    tasks =
      for title <- titles, do: Board.group_task!(Board.create_task!(%{title: title}), group.id)

    {group, tasks}
  end

  test "a cron's close runs show as one stack, not two cards", %{conn: conn} do
    cron =
      Recurring.create_cron!(%{
        name: "Inbox",
        workflow_id: Workflows.default_workflow!().id,
        mode: :expression,
        expression: "*/30 * * * *",
        timezone: "Etc/UTC"
      })

    Recurring.claim_cron!(cron, %{next_run_at: ~U[2026-11-02 08:00:00Z]})
    {:ok, view, _html} = live(conn, ~p"/")

    # Refused by the default workflow (no planner): both stay in backlog.
    :ok = Runner.start_due(~U[2026-11-02 08:01:00Z])
    :ok = Runner.start_due(~U[2026-11-02 08:31:00Z])
    _ = render(view)

    [group] = Board.list_task_groups!()
    assert has_element?(view, "#{stack(group, :backlog)}-count", "×2")
    assert has_element?(view, "#{stack(group, :backlog)} [data-tag='CRON']")
    assert has_element?(view, "#{stack(group, :backlog)}-span", "08:00–08:30")

    for task <- Board.list_tasks!() do
      refute has_element?(view, "#backlog-#{task.id}")
      assert has_element?(view, "#{stack(group, :backlog)} #task-link-#{task.id}")
    end
  end

  test "tasks are grouped from the drawer and ungrouped from their stack", %{conn: conn} do
    first = Board.create_task!(%{title: "Release notes"})
    second = Board.create_task!(%{title: "Changelog"})
    {:ok, view, _html} = live(conn, ~p"/tasks/#{first.id}/edit")

    view |> form("#task-drawer-group", %{group_id: "new"}) |> render_change()
    view |> form("#task-drawer-new-group", %{name: "Release 2.3"}) |> render_submit()

    [group] = Board.list_task_groups!()
    assert group.name == "Release 2.3"
    assert has_element?(view, "#{stack(group, :backlog)}-count", "×1")
    refute has_element?(view, "#backlog-#{first.id}")

    render_patch(view, ~p"/tasks/#{second.id}/edit")
    view |> form("#task-drawer-group", %{group_id: group.id}) |> render_change()
    assert has_element?(view, "#{stack(group, :backlog)}-count", "×2")
    refute has_element?(view, "#backlog-#{second.id}")

    # Moving one on its own splits the stack across columns.
    Board.move_task!(Board.get_task!(second.id), :canceled)
    _ = render(view)
    assert has_element?(view, "#{stack(group, :backlog)}-count", "×1")
    assert has_element?(view, "#{stack(group, :canceled)}-count", "×1")

    view |> element("#{stack(group, :backlog)}-ungroup") |> render_click()
    assert has_element?(view, "#backlog-#{first.id}")
    assert has_element?(view, "#canceled-#{second.id}")
    refute has_element?(view, "[data-group-card]")
    assert Board.list_task_groups!() == []
  end

  test "dragging a stack moves every task of it in that column", %{conn: conn} do
    {group, tasks} = grouped!("Release 2.3", ["Release notes", "Changelog"])
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             ~s|#{stack(group, :backlog)}[draggable="true"][data-group-id="#{group.id}"][data-count="2"]|
           )

    # What the board hook pushes once the person confirms the drop.
    render_hook(view, "move_group", %{
      "group_id" => group.id,
      "from" => "backlog",
      "status" => "canceled"
    })

    refute has_element?(view, stack(group, :backlog))
    assert has_element?(view, "#{stack(group, :canceled)}-count", "×2")
    assert Enum.all?(tasks, &(Board.get_task!(&1.id).status == :canceled))
  end
end
