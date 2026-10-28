defmodule Weworkai.Recurring.RunnerTest do
  use Weworkai.DataCase, async: false

  @moduletag :capture_log

  alias Weworkai.{Board, Notifications, Recurring, Workflows}
  alias Weworkai.Recurring.Runner

  defp weekly(days, at, timezone), do: %{mode: :weekly, days: days, at: at, timezone: timezone}
  defp expression(text, timezone), do: %{mode: :expression, expression: text, timezone: timezone}

  describe "next_run/2, weekly" do
    # 28 Oct 2026 is a Wednesday; Warsaw is on CET (UTC+1) since the 25th.
    test "later today, else the next allowed day" do
      weekdays = weekly([1, 2, 3, 4, 5], ~T[09:00:00], "Europe/Warsaw")

      assert Runner.next_run(weekdays, ~U[2026-10-28 07:00:00Z]) == ~U[2026-10-28 08:00:00Z]
      assert Runner.next_run(weekdays, ~U[2026-10-28 08:00:00Z]) == ~U[2026-10-29 08:00:00Z]
      assert Runner.next_run(weekdays, ~U[2026-10-30 09:00:00Z]) == ~U[2026-11-02 08:00:00Z]

      assert Runner.next_run(weekly([3], ~T[09:00:00], "Etc/UTC"), ~U[2026-10-28 10:00:00Z]) ==
               ~U[2026-11-04 09:00:00Z]
    end

    test "a time the clocks skip runs when they resume; one they pass twice, the first time" do
      sunday = weekly([7], ~T[02:30:00], "Europe/Warsaw")
      # 29 Mar 2026: 02:00 CET jumps to 03:00 CEST (01:00 UTC).
      assert Runner.next_run(sunday, ~U[2026-03-28 12:00:00Z]) == ~U[2026-03-29 01:00:00Z]
      # 25 Oct 2026: 03:00 CEST falls back to 02:00 CET; 02:30 happens at 00:30 and 01:30 UTC.
      assert Runner.next_run(sunday, ~U[2026-10-24 12:00:00Z]) == ~U[2026-10-25 00:30:00Z]
    end
  end

  describe "next_run/2, expression" do
    test "matches from the minute after, on the zone's clock" do
      half_hourly = expression("*/30 8-18 * * *", "Etc/UTC")

      assert Runner.next_run(half_hourly, ~U[2026-10-28 07:59:30Z]) == ~U[2026-10-28 08:00:00Z]
      assert Runner.next_run(half_hourly, ~U[2026-10-28 08:00:00Z]) == ~U[2026-10-28 08:30:00Z]
      assert Runner.next_run(half_hourly, ~U[2026-10-28 18:30:00Z]) == ~U[2026-10-29 08:00:00Z]

      # Weekdays at 9:00 in Warsaw (CET): Friday afternoon → Monday 08:00 UTC.
      assert Runner.next_run(expression("0 9 * * 1-5", "Europe/Warsaw"), ~U[2026-10-30 12:00:00Z]) ==
               ~U[2026-11-02 08:00:00Z]
    end

    test "a skipped time runs when the clocks resume; the repeated hour fires once" do
      nightly = expression("30 2 * * *", "Europe/Warsaw")
      assert Runner.next_run(nightly, ~U[2026-03-28 12:00:00Z]) == ~U[2026-03-29 01:00:00Z]

      # 01:10 UTC is 02:10 the second time round; 02:30's first moment (00:30 UTC) is past.
      assert Runner.next_run(nightly, ~U[2026-10-25 01:10:00Z]) == ~U[2026-10-26 01:30:00Z]
    end

    test "any expression that parses and runs is a cron's, however often" do
      assert Runner.check_expression("0 9 * * 1-5") == :ok
      assert Runner.check_expression("* * * * *") == :ok

      assert Runner.check_expression("every morning") ==
               {:error, "is not a valid cron expression"}

      assert Runner.check_expression("0 0 30 2 *") == {:error, "never runs"}
      assert Runner.check_expression("@reboot") == {:error, "@reboot is not supported"}
      assert Runner.preview("@reboot", "Etc/UTC") == {:error, "@reboot is not supported"}
    end
  end

  # Look --seen--> Done: a human start block, so the task starts with no agent at all.
  defp human_workflow! do
    {:ok, workflow} = Workflows.create_workflow("Morning check", nil, %{empty: true})

    {:ok, %{workflow: workflow, problems: []}} =
      Workflows.save_graph(workflow, %{
        nodes: [
          %{id: "n1", kind: "human", label: "Look", start: true},
          %{id: "n2", kind: "column", label: "Done", column_status: "done", x: 300}
        ],
        edges: [%{id: "e1", from: "n1", to: "n2", condition: "seen"}]
      })

    workflow
  end

  defp cron!(workflow, attrs \\ %{}) do
    Recurring.create_cron!(
      Map.merge(
        %{
          name: "Check comments",
          workflow_id: workflow.id,
          days: [1, 2, 3, 4, 5, 6, 7],
          at: ~T[09:00:00],
          timezone: "Etc/UTC",
          description: "Did anyone comment on our posts?",
          repository: "/repos/app"
        },
        attrs
      )
    )
  end

  # Pins the next slot, so a test's clock doesn't depend on today's.
  defp due_at!(cron, slot), do: Recurring.claim_cron!(cron, %{next_run_at: slot})

  test "a due cron creates a CRON task for its slot and starts the workflow, once" do
    workflow = human_workflow!()
    cron = cron!(workflow)
    slot = cron.next_run_at
    now = DateTime.add(slot, 5, :minute)

    :ok = Runner.start_due(now)

    [task] = Board.list_tasks!()
    assert task.tags == ["CRON"]
    assert %{cron_id: cron_id, cron_run_at: ^slot, group_id: nil} = task
    assert cron_id == cron.id
    assert task.title =~ ~r/^Check comments · \w{3} \d{2} \w{3}$/
    assert %{status: :await_human_supervision, repository: "/repos/app"} = task
    assert task.workflow_id == workflow.id

    cron = Recurring.get_cron!(cron.id, load: [:task_count, :last_task_id])
    assert %{task_count: 1, last_run_at: ^now, last_error: nil} = cron
    assert cron.last_task_id == task.id
    assert DateTime.compare(cron.next_run_at, now) == :gt

    # Claimed: the same tick again fires nothing.
    :ok = Runner.start_due(now)
    assert length(Board.list_tasks!()) == 1
  end

  test "a slot missed by more than the grace window is skipped" do
    cron = cron!(human_workflow!())
    slot = cron.next_run_at
    now = DateTime.add(slot, Runner.grace_minutes() + 60, :minute)

    :ok = Runner.start_due(now)

    assert Board.list_tasks!() == []
    cron = Recurring.get_cron!(cron.id)
    assert cron.last_skipped_at == slot
    assert cron.last_run_at == nil
    assert DateTime.compare(cron.next_run_at, now) == :gt
  end

  test "after a long outage an hourly cron fires its newest slot within the window, once" do
    cron = cron!(human_workflow!(), %{mode: :expression, expression: "0 * * * *"})
    cron = due_at!(cron, ~U[2026-11-02 08:00:00Z])
    now = ~U[2026-11-02 11:10:00Z]

    # Skips the old slots, then fires the one 10 minutes ago.
    for _tick <- 1..3, do: :ok = Runner.start_due(now)

    [task] = Board.list_tasks!()
    assert task.cron_run_at == ~U[2026-11-02 11:00:00.000000Z]
    assert task.title == "Check comments · Mon 02 Nov 11:00"
    assert Recurring.get_cron!(cron.id).last_skipped_at == ~U[2026-11-02 08:00:00.000000Z]
  end

  test "after an outage a frequent cron fires the newest slot within the window" do
    cron = cron!(human_workflow!(), %{mode: :expression, expression: "*/5 * * * *"})
    due_at!(cron, ~U[2026-11-02 08:00:00Z])
    now = ~U[2026-11-02 11:10:00Z]

    for _tick <- 1..3, do: :ok = Runner.start_due(now)

    [task] = Board.list_tasks!()
    assert task.cron_run_at == ~U[2026-11-02 11:10:00.000000Z]
    assert task.title == "Check comments · Mon 02 Nov 11:10"
  end

  test "a missed slot stays recorded through the catch-up run, and clears at the next" do
    cron = cron!(human_workflow!(), %{mode: :expression, expression: "0 * * * *"})
    due_at!(cron, ~U[2026-11-02 08:00:00Z])

    :ok = Runner.start_due(~U[2026-11-02 11:10:00Z])
    :ok = Runner.start_due(~U[2026-11-02 11:10:01Z])
    assert Recurring.get_cron!(cron.id).last_skipped_at == ~U[2026-11-02 08:00:00.000000Z]

    :ok = Runner.start_due(~U[2026-11-02 12:00:30Z])
    assert Recurring.get_cron!(cron.id).last_skipped_at == nil
    assert length(Board.list_tasks!()) == 2
  end

  test "runs close together share the cron's group; the first joins it" do
    cron = cron!(human_workflow!(), %{mode: :expression, expression: "*/30 * * * *"})
    due_at!(cron, ~U[2026-11-02 08:00:00Z])

    :ok = Runner.start_due(~U[2026-11-02 08:01:00Z])
    :ok = Runner.start_due(~U[2026-11-02 08:31:00Z])

    [first, second] = Enum.sort_by(Board.list_tasks!(), & &1.cron_run_at, DateTime)
    assert first.group_id
    assert first.group_id == second.group_id
    assert %{name: "Check comments · Mon 02 Nov", cron_id: cron_id} = second.group
    assert cron_id == cron.id
  end

  test "runs far apart stay apart" do
    cron = cron!(human_workflow!(), %{mode: :expression, expression: "0 9 * * *"})
    due_at!(cron, ~U[2026-11-02 09:00:00Z])

    :ok = Runner.start_due(~U[2026-11-02 09:01:00Z])
    :ok = Runner.start_due(~U[2026-11-03 09:01:00Z])

    assert [nil, nil] = Enum.map(Board.list_tasks!(), & &1.group_id)
    assert Board.list_task_groups!() == []
  end

  test "a run a person grouped starts no cron group" do
    cron = cron!(human_workflow!(), %{mode: :expression, expression: "*/30 * * * *"})
    due_at!(cron, ~U[2026-11-02 08:00:00Z])
    :ok = Runner.start_due(~U[2026-11-02 08:01:00Z])

    [first] = Board.list_tasks!()
    mine = Board.create_task_group!("Mine")
    Board.group_task!(first, mine.id)

    :ok = Runner.start_due(~U[2026-11-02 08:31:00Z])
    second = Enum.find(Board.list_tasks!(), &(&1.id != first.id))
    assert second.group_id == nil
    assert Board.get_task!(first.id).group_id == mine.id
  end

  test "a task its workflow refuses stays in backlog, and says why" do
    # The default workflow starts on a Planner, and there is no planner agent.
    cron = cron!(Workflows.default_workflow!())

    assert {:error, reason} = Runner.start(cron)
    assert reason =~ "can't run"

    [task] = Board.list_tasks!()
    assert %{status: :backlog, tags: ["CRON"]} = task
    assert Recurring.get_cron!(cron.id).last_error == reason
    assert [%{kind: :cron_failed, body: ^reason}] = Notifications.recent_notifications!()
  end

  test "a paused cron is never due" do
    cron = cron!(human_workflow!(), %{enabled: false})
    assert cron.next_run_at == nil
    assert Recurring.due_crons!(DateTime.add(DateTime.utc_now(), 30, :day)) == []
  end

  test "an expression cron needs a valid expression" do
    workflow = human_workflow!()

    assert {:error, error} =
             Recurring.create_cron(%{
               name: "Bad",
               workflow_id: workflow.id,
               mode: :expression,
               expression: "9am"
             })

    assert Exception.message(error) =~ "is not a valid cron expression"

    assert {:error, error} =
             Recurring.create_cron(%{name: "Blank", workflow_id: workflow.id, mode: :expression})

    assert Exception.message(error) =~ "is required"
  end

  test "a workflow crons run can't be deleted" do
    workflow = human_workflow!()
    cron!(workflow)

    assert {:error, error} = Workflows.destroy_workflow(workflow)
    assert Exception.message(error) =~ "1 cron still run this workflow"
  end
end
