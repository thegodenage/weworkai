defmodule WeworkaiWeb.TaskDependenciesLiveTest do
  use WeworkaiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Weworkai.Board

  defp task(title), do: Board.create_task!(%{title: title})

  test "a blocker added on the task page marks it blocked; removing it frees it", %{conn: conn} do
    api = task("API")
    ui = task("UI")
    {:ok, view, _html} = live(conn, ~p"/tasks/#{ui.id}")

    refute has_element?(view, "#task-blocked")

    view
    |> form("#task-dependencies-blocker-form", blocker: %{blocker_id: api.id})
    |> render_submit()

    assert has_element?(view, "#task-dependencies-blocker-#{api.id}")
    assert has_element?(view, "#task-blocked")

    view |> element("#task-dependencies-remove-#{api.id}") |> render_click()

    refute has_element?(view, "#task-dependencies-blocker-#{api.id}")
    refute has_element?(view, "#task-blocked")
  end

  test "a blocker that would close a loop is refused, saying why", %{conn: conn} do
    api = task("API")
    ui = task("UI")
    Board.add_blocker!(ui.id, api.id)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{api.id}")

    view
    |> form("#task-dependencies-blocker-form", blocker: %{blocker_id: ui.id})
    |> render_submit()

    assert has_element?(view, "#task-dependencies-error")
    refute has_element?(view, "#task-dependencies-blocker-#{ui.id}")
    assert has_element?(view, "#task-dependencies-dependents", "UI")
  end

  test "the blocker closing elsewhere unblocks the page live", %{conn: conn} do
    api = task("API")
    ui = task("UI")
    Board.add_blocker!(ui.id, api.id)
    {:ok, view, _html} = live(conn, ~p"/tasks/#{ui.id}")
    assert has_element?(view, "#task-blocked")

    Board.move_task!(api, :done)

    refute has_element?(view, "#task-blocked")
  end

  test "sub-tasks are added on the parent's page with their progress", %{conn: conn} do
    epic = task("Epic")
    {:ok, view, _html} = live(conn, ~p"/tasks/#{epic.id}")

    for title <- ["One", "Two"] do
      view
      |> form("#task-dependencies-subtask-form", subtask: %{title: title})
      |> render_submit()
    end

    [first, _second] = Board.get_task!(epic.id, load: :children).children
    assert has_element?(view, "#task-dependencies-child-#{first.id}")
    assert has_element?(view, "#task-dependencies-progress", "0/2")

    Board.move_task!(first, :done)

    assert has_element?(view, "#task-dependencies-progress", "1/2")

    {:ok, child_view, _html} = live(conn, ~p"/tasks/#{first.id}")
    assert has_element?(child_view, "#task-dependencies-parent", "Epic")
  end

  test "board cards show a blocked marker and sub-task progress", %{conn: conn} do
    api = task("API")
    ui = task("UI")
    Board.add_blocker!(ui.id, api.id)
    Board.create_subtask!(ui.id, "Form")
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#task-#{ui.id}-blocked")
    assert has_element?(view, "#task-#{ui.id}-subtasks", "0/1")
    refute has_element?(view, "#task-#{api.id}-blocked")

    Board.move_task!(api, :done)

    refute has_element?(view, "#task-#{ui.id}-blocked")
  end
end
