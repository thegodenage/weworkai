defmodule WeworkaiWeb.NotificationsLiveTest do
  use WeworkaiWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Weworkai.{Board, Notifications}

  defp notify(task, title \\ "Plan ready") do
    Notifications.notify!(%{
      task_id: task.id,
      kind: :plan_ready,
      title: title,
      body: "Review it."
    })
  end

  setup do
    %{task: Board.create_task!(%{title: "Greet users"})}
  end

  test "the bell counts new notifications live, on any page", %{conn: conn, task: task} do
    {:ok, board, _html} = live(conn, ~p"/")
    {:ok, employees, _html} = live(conn, ~p"/employees")

    refute has_element?(board, "#notification-bell-count")
    assert has_element?(board, "#notification-list-empty")

    notification = notify(task)

    for view <- [board, employees] do
      assert has_element?(view, "#notification-bell-count", "1")
      assert has_element?(view, "#notification-#{notification.id}[data-unread]", "Plan ready")
      assert_push_event(view, "notification", %{id: id, title: "Plan ready"})
      assert id == notification.id
    end

    notify(task, "Coder started")
    assert has_element?(employees, "#notification-bell-count", "2")
  end

  test "opening a notification marks it read and opens its task", %{conn: conn, task: task} do
    notification = notify(task)
    {:ok, view, _html} = live(conn, ~p"/dashboard")
    assert has_element?(view, "#notification-bell-count", "1")

    view |> element("#notification-#{notification.id}") |> render_click()

    assert_redirect(view, ~p"/tasks/#{task.id}")
    assert Notifications.unread_notification_count!() == 0
  end

  test "marks all notifications read from the bell", %{conn: conn, task: task} do
    notify(task)
    notify(task, "Coder started")
    {:ok, view, _html} = live(conn, ~p"/connectors")
    assert has_element?(view, "#notification-bell-count", "2")

    view |> element("#mark-all-notifications-read") |> render_click()

    refute has_element?(view, "#notification-bell-count")
    refute has_element?(view, "#notification-list [data-unread]")
    assert Notifications.unread_notification_count!() == 0
  end

  test "reading notifications in one tab clears them in the others", %{conn: conn, task: task} do
    first = notify(task)
    notify(task, "Coder started")
    {:ok, board, _html} = live(conn, ~p"/")
    {:ok, inbox, _html} = live(conn, ~p"/notifications?filter=unread")

    board |> element("#notification-#{first.id}") |> render_click()
    assert has_element?(inbox, "#notification-bell-count", "1")
    refute has_element?(inbox, "#inbox-#{first.id}")

    {:ok, connectors, _html} = live(conn, ~p"/connectors")
    connectors |> element("#mark-all-notifications-read") |> render_click()
    refute has_element?(inbox, "#notification-bell-count")
    assert has_element?(inbox, "#inbox-empty")
  end

  test "the task page reacts to its own notifications and keeps the bell", %{
    conn: conn,
    task: task
  } do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    notify(task)

    assert has_element?(view, "#notification-bell-count", "1")
    assert has_element?(view, "#task-title", "Greet users")
  end

  test "the notifications page lists and filters unread ones", %{conn: conn, task: task} do
    read = notify(task, "Old news")
    Notifications.mark_notification_read!(read)
    unread = notify(task, "Plan ready")

    {:ok, view, _html} = live(conn, ~p"/notifications")
    assert has_element?(view, "#inbox-#{read.id}", "Old news")
    assert has_element?(view, "#inbox-#{unread.id}-open[data-unread]", "Plan ready")

    view |> element("#filter-unread") |> render_click()
    assert_patch(view, ~p"/notifications?filter=unread")
    refute has_element?(view, "#inbox-#{read.id}")
    assert has_element?(view, "#inbox-#{unread.id}")

    fresh = notify(task, "Coder started")
    assert has_element?(view, "#inbox-#{fresh.id}", "Coder started")

    view |> element("#notifications-mark-all-read") |> render_click()
    refute has_element?(view, "#inbox li:not(#inbox-empty)")
    assert has_element?(view, "#inbox-empty")

    view |> element("#filter-all") |> render_click()
    assert has_element?(view, "#inbox-#{fresh.id}")
    refute has_element?(view, "#inbox [data-unread]")
  end
end
