defmodule Weworkai.Workflows.BudgetTest do
  use Weworkai.DataCase, async: false

  # Refused starts are logged.
  @moduletag :capture_log

  alias Weworkai.{Agents, Board, BridgeStub, Connectors, Notifications, Organization}
  alias Weworkai.{ErrorText, Scheduling}
  alias Weworkai.Agents.Agent.BudgetPeriod
  alias Weworkai.Agents.Budget
  alias Weworkai.Agents.Errors.OverBudget

  # Every stub run costs $0.0525 (BridgeStub.usage/0).

  setup do
    connector = Connectors.create_connector!(%{name: "Claude", provider: :claude_code})
    %{bridge: BridgeStub.start(), connector: connector}
  end

  defp agent(connector, name, role, budget \\ %{}) do
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
    |> Ash.Changeset.force_change_attributes(Map.put(budget, :model, "claude-opus-5-5"))
    |> Ash.update!()

    employee
  end

  defp planned_task(bridge, budget) do
    task = Board.create_task!(%{title: "Greet users", repository: "/repos/app"})
    task = if budget, do: Board.set_task_budget!(task, budget), else: task
    Board.move_task!(task, :todo)
    BridgeStub.step(bridge)
    Board.get_task!(task.id)
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

  defp notification_kinds, do: Enum.map(Notifications.recent_notifications!(), & &1.kind)

  defp budget_events(task),
    do: for(%{kind: :budget, label: label} <- Board.list_events!(task.id), do: label)

  describe "marks" do
    defp budget(spent, cap),
      do: %Budget{owner: :task, cap: Decimal.new(cap), spent: Decimal.new(spent)}

    test "a run is noted when it takes the budget past 80% or past the cap, once" do
      assert Budget.crossed(budget("0.79", "1"), Decimal.new("0.1")) == []
      assert [{:warning, _}] = Budget.crossed(budget("0.8", "1"), Decimal.new("0.1"))
      assert Budget.crossed(budget("0.9", "1"), Decimal.new("0.05")) == []
      assert [{:reached, _}] = Budget.crossed(budget("1", "1"), Decimal.new("0.15"))
      assert [{:reached, _}] = Budget.crossed(budget("1.5", "1"), Decimal.new("1.5"))
      assert Budget.crossed(budget("1.2", "1"), Decimal.new("0.1")) == []
    end

    test "a day starts at midnight UTC, a week on Monday" do
      wednesday = ~U[2026-10-28 15:30:00Z]
      assert BudgetPeriod.start(:day, wednesday) == ~U[2026-10-28 00:00:00Z]
      assert BudgetPeriod.start(:week, wednesday) == ~U[2026-10-26 00:00:00Z]
    end
  end

  describe "a task's budget" do
    setup %{connector: connector}, do: %{planner: agent(connector, "Ann", :planner)}

    test "80% spent is noted on the task and notified", %{bridge: bridge} do
      task = planned_task(bridge, "0.06")

      assert budget_events(task) == ["Budget 80% spent"]
      assert :budget_warning in notification_kinds()
      assert hd(Notifications.recent_notifications!()).body =~ "$0.0525 of its $0.0600 budget"
    end

    test "once spent, the next run is refused and a human takes over; a raised cap lets Continue run it",
         %{bridge: bridge} do
      task = planned_task(bridge, "0.05")
      assert budget_events(task) == ["Budget reached"]
      assert :budget_reached in notification_kinds()
      started_runs()

      task = Board.comment_on_plan!(task, "Shorter")
      BridgeStub.step(bridge)

      assert started_runs() == []
      task = Board.get_task!(task.id)
      assert task.status == :await_human_supervision
      assert %{status: :failed} = Scheduling.latest_job!(task.id)

      assert List.last(Board.list_messages!(task.id)).body ==
               "The planner can't start: Budget reached. This task has spent $0.0525 of its " <>
                 "$0.0500 budget. Raise the task's budget on its page, then Continue."

      task = Board.set_task_budget!(task, "1")
      Board.continue_task!(task)
      BridgeStub.step(bridge)

      assert [%{"profile" => "planner"}] = started_runs()
    end

    test "a task without one runs uncapped", %{bridge: bridge} do
      task = planned_task(bridge, nil)

      assert budget_events(task) == []
      assert Budget.task(task) == nil
    end

    test "must be positive", %{bridge: bridge} do
      task = planned_task(bridge, nil)
      assert {:error, %Ash.Error.Invalid{}} = Board.set_task_budget(task, "0")
    end
  end

  describe "an agent's budget" do
    test "counts its runs this period; once spent, it starts no new run",
         %{bridge: bridge, connector: connector} do
      agent(connector, "Ann", :planner, %{budget_usd: Decimal.new("0.05"), budget_period: :week})

      task = planned_task(bridge, nil)
      assert budget_events(task) == ["Budget reached"]

      other = Board.create_task!(%{title: "Other", repository: "/repos/app"})
      Board.move_task!(other, :todo)
      job = Scheduling.latest_job!(other.id)

      assert {:error, %OverBudget{} = error} = Budget.allow(job)

      assert ErrorText.readable(error) ==
               "Budget reached. Ann has spent $0.0525 of a $0.0500 weekly budget. " <>
                 "Raise it on the Employees page, then Continue."

      BridgeStub.step(bridge)
      assert %{status: :await_human_supervision} = Board.get_task!(other.id)
    end
  end
end
