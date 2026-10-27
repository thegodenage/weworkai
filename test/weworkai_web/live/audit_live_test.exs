defmodule WeworkaiWeb.AuditLiveTest do
  use WeworkaiWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Weworkai.{Agents, Board, BridgeStub, Connectors, Organization}

  test "the sidebar leads to the audit page, which lists every task", %{conn: conn} do
    task = Board.create_task!(%{title: "Audit me"})
    {:ok, board, _html} = live(conn, ~p"/")
    assert has_element?(board, ~s(nav a[href="/audit"]), "Audit")

    {:ok, view, _html} = live(conn, ~p"/audit")
    assert has_element?(view, "#audit-task-#{task.id}", "Audit me")
    assert has_element?(view, "#audit-empty")
  end

  test "picking a task opens its timeline, a move a human made as a point", %{conn: conn} do
    task = Board.create_task!(%{title: "Moved"})
    Board.move_task!(task, :done)
    {:ok, view, _html} = live(conn, ~p"/audit")

    view |> element("#audit-task-#{task.id}") |> render_click()

    assert_patch(view, ~p"/audit/#{task.id}")
    assert has_element?(view, "#audit-title", "Moved")
    assert has_element?(view, "#gantt-lane-people [data-kind=move]")
    assert has_element?(view, "#audit-stat-steps", "1")
  end

  test "a task nothing happened on yet says so", %{conn: conn} do
    task = Board.create_task!(%{title: "Fresh"})
    {:ok, view, _html} = live(conn, ~p"/audit/#{task.id}")
    assert has_element?(view, "#audit-timeline-empty")
  end

  test "searching narrows the list", %{conn: conn} do
    Board.create_task!(%{title: "Alpha"})
    beta = Board.create_task!(%{title: "Beta"})
    {:ok, view, _html} = live(conn, ~p"/audit")

    view |> form("#audit-search", %{query: "bet"}) |> render_change()

    assert has_element?(view, "#audit-task-#{beta.id}")
    refute has_element?(view, "#audit-task-list", "Alpha")
  end

  describe "cost ledger" do
    setup do
      connector = Connectors.create_connector!(%{name: "Claude", provider: :claude_code})
      bridge = BridgeStub.start()

      employee =
        Organization.create_employee!(%{
          kind: :agent,
          name: "Planner Pat",
          agent_role: :planner,
          connector_id: connector.id
        })

      # Skips :configure, whose check would ask the bridge for its model list.
      employee.agent_id
      |> Agents.get_agent!()
      |> Ash.Changeset.for_update(:assign_role, %{role: :planner})
      |> Ash.Changeset.force_change_attributes(%{model: "claude-opus-5-5"})
      |> Ash.update!()

      task = Board.create_task!(%{title: "Planned", repository: "/repos/app"})
      Board.move_task!(task, :todo)
      BridgeStub.step(bridge)
      %{task: task, employee: employee}
    end

    test "the audit page totals the last week's spend per agent", %{
      conn: conn,
      employee: employee
    } do
      {:ok, view, _html} = live(conn, ~p"/audit")

      assert has_element?(view, "#audit-spend-#{employee.agent_id}", "Planner Pat")
      assert has_element?(view, "#audit-spend-#{employee.agent_id}", "$0.0525")
    end

    test "a task's timeline adds up its runs' tokens and cost, per bar too",
         %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/audit/#{task.id}")

      assert has_element?(view, "#audit-stat-tokens", "4.6k")
      assert has_element?(view, "#audit-stat-cost", "$0.0525")

      view |> element("[id^=gantt-bar-]") |> render_click()
      assert has_element?(view, "#audit-bar-usage", "4.6k tok · $0.0525")
    end
  end
end
