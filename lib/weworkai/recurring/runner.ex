defmodule Weworkai.Recurring.Runner do
  @moduledoc """
  Fires crons (docs/recurring.md). `next_run/2` finds a cron's next slot, from weekdays and
  a time or from a cron expression, on the wall clock of its time zone; `start_due/1`,
  called on every scheduler tick, fires the crons whose slot has come: each creates a task
  on its workflow, tagged CRON, and moves it to todo, which starts the workflow as a
  person moving it would. A cron is claimed (its next slot set) before its task is made,
  so a run that fails or raises is never repeated every tick.

  A slot more than `grace_minutes/0` old (the app wasn't running then) is skipped, not
  fired late; after a long outage the newest slot still within the window fires, once.
  Runs at most `group_gap_minutes/0` apart on the same day share a task group, shown on
  the board as one stack.
  """
  require Logger

  alias Crontab.CronExpression.Parser
  alias Weworkai.{Board, ErrorText, Notifications, Recurring, Workflows}

  @grace_minutes 60
  @group_gap_minutes 60

  @doc "How late a slot may still fire."
  def grace_minutes, do: @grace_minutes

  @doc "How far apart a cron's runs may come and still share a group."
  def group_gap_minutes, do: @group_gap_minutes

  @doc """
  The schedule's first slot after `from`, in UTC: `%{mode: :weekly, days, at, timezone}`
  (ISO weekdays, 1 = Monday) or `%{mode: :expression, expression, timezone}`; nil for an
  expression that never matches. Both run on the zone's wall clock: a time the clocks skip
  (DST) runs when they resume, one they pass twice the first time.
  """
  @spec next_run(map(), DateTime.t()) :: DateTime.t() | nil
  def next_run(%{mode: :expression} = schedule, from) do
    {:ok, expression} = parse(schedule.expression)
    next_match(expression, schedule.timezone, from)
  end

  def next_run(schedule, from) do
    today = from |> DateTime.shift_zone!(schedule.timezone) |> DateTime.to_date()

    # Today's slot may have passed: the same weekday next week is the last candidate.
    0..7
    |> Stream.map(&Date.add(today, &1))
    |> Stream.filter(&(Date.day_of_week(&1) in schedule.days))
    |> Stream.map(&local(&1, schedule.at, schedule.timezone))
    |> Enum.find(&(DateTime.compare(&1, from) == :gt))
    |> DateTime.shift_zone!("Etc/UTC")
  end

  # The expression is matched on the local clock from the minute after `from`. A match in
  # the hour the clocks pass twice can land at or before `from` (its first moment came
  # already): that one is passed over, so nothing fires twice.
  defp next_match(expression, timezone, from) do
    local_from = from |> DateTime.shift_zone!(timezone) |> DateTime.to_naive()
    start = NaiveDateTime.add(%{local_from | second: 0, microsecond: {0, 0}}, 60)
    match_from(expression, timezone, from, start)
  end

  defp match_from(expression, timezone, from, start) do
    case Crontab.Scheduler.get_next_run_date(expression, start) do
      {:ok, naive} ->
        moment = local(NaiveDateTime.to_date(naive), NaiveDateTime.to_time(naive), timezone)

        if DateTime.compare(moment, from) == :gt,
          do: DateTime.shift_zone!(moment, "Etc/UTC"),
          else: match_from(expression, timezone, from, NaiveDateTime.add(naive, 60))

      {:error, _never} ->
        nil
    end
  end

  defp local(date, time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, datetime} -> datetime
      {:ambiguous, first, _second} -> first
      {:gap, _before, resumed} -> resumed
    end
  end

  defp parse(expression) do
    case Parser.parse(String.trim(expression)) do
      # It parses, but has no dates: the scheduler raises on it.
      {:ok, %{reboot: true}} -> {:error, "@reboot is not supported"}
      {:ok, parsed} -> {:ok, parsed}
      {:error, _message} -> {:error, "is not a valid cron expression"}
    end
  end

  @doc "`:ok` for an expression a cron may run on: it parses and matches some date; else why not."
  @spec check_expression(String.t()) :: :ok | {:error, String.t()}
  def check_expression(expression) do
    with {:ok, parsed} <- parse(expression) do
      if next_match(parsed, "Etc/UTC", DateTime.utc_now()),
        do: :ok,
        else: {:error, "never runs"}
    end
  end

  @doc "The next `count` runs of an expression typed in the form, or an error while it has none."
  def preview(expression, timezone, count \\ 3)

  def preview(expression, timezone, count) when is_binary(expression) and is_binary(timezone) do
    with {:ok, _now} <- DateTime.now(timezone),
         {:ok, parsed} <- parse(expression) do
      runs =
        DateTime.utc_now()
        |> Stream.unfold(fn from ->
          case next_match(parsed, timezone, from) do
            nil -> nil
            next -> {next, next}
          end
        end)
        |> Enum.take(count)

      {:ok, runs}
    end
  end

  def preview(_expression, _timezone, _count), do: {:error, :blank}

  @doc "Fires (or skips, when too late) every cron due as of `now`; one that raises leaves the others be."
  def start_due(now \\ DateTime.utc_now()) do
    Enum.each(Recurring.due_crons!(now), fn cron ->
      try do
        if DateTime.diff(now, cron.next_run_at, :minute) > @grace_minutes,
          do: skip!(cron, now),
          else: start(cron, now, cron.next_run_at)
      rescue
        error ->
          Logger.error(
            "Recurring: cron #{cron.id} raised\n" <>
              Exception.format(:error, error, __STACKTRACE__)
          )
      end
    end)
  end

  # The next slot is the newest within the grace window: when one has come already (a cron
  # running several times a day, back after an outage), the next tick fires it, once; the
  # older ones in the window are skipped too.
  defp skip!(cron, now) do
    Recurring.claim_cron!(cron, %{
      next_run_at:
        newest_slot(cron, next_slot(cron, DateTime.add(now, -@grace_minutes, :minute)), now),
      last_skipped_at: cron.next_run_at
    })
  end

  # The last slot from `slot` on that has come by `now`; `slot` itself when it is still ahead.
  defp newest_slot(cron, slot, now) do
    with %DateTime{} <- slot,
         %DateTime{} = next <- next_slot(cron, slot),
         true <- DateTime.compare(next, now) != :gt do
      newest_slot(cron, next, now)
    else
      _ahead -> slot
    end
  end

  @doc """
  Runs the cron for `slot` (its due slot, or now for Run now): claims it, creates its task
  (in the group of the runs close to it) and moves it to todo. `{:error, reason}` when the
  task couldn't be created or its workflow refused to start; the cron records why and a
  notification goes out.
  """
  @spec start(Weworkai.Recurring.Cron.t(), DateTime.t(), DateTime.t() | nil) ::
          {:ok, Weworkai.Board.Task.t()} | {:error, String.t()}
  def start(cron, now \\ DateTime.utc_now(), slot \\ nil) do
    slot = slot || now

    cron =
      Recurring.claim_cron!(
        cron,
        Map.merge(
          %{last_run_at: now, next_run_at: next_slot(cron, now)},
          missed_seen(cron)
        )
      )

    with {:ok, task} <- create_task(cron, slot, group_id(cron, slot)) do
      case Board.move_task(task, :todo) do
        {:ok, started} ->
          Recurring.record_cron_run!(cron, %{last_error: nil})
          {:ok, started}

        {:error, error} ->
          failed!(cron, task, ErrorText.readable(error))
      end
    else
      {:error, error} -> failed!(cron, nil, ErrorText.readable(error))
    end
  end

  # A skipped slot stays shown through the run that caught up after it, and is cleared by
  # the run after that.
  defp missed_seen(%{last_skipped_at: %DateTime{} = skipped, last_run_at: %DateTime{} = ran}) do
    if DateTime.compare(ran, skipped) == :gt, do: %{last_skipped_at: nil}, else: %{}
  end

  defp missed_seen(_cron), do: %{}

  # A paused cron run by hand stays paused: no next slot.
  defp next_slot(%{enabled: false}, _from), do: nil
  defp next_slot(cron, from), do: next_run(cron, from)

  # Runs close together (at most `group_gap_minutes/0` apart, on the same day of the
  # cron's clock) share the cron's group: a half-hourly cron leaves one stack a day, not
  # twenty cards. A run a person moved into a group of their own starts none.
  defp group_id(cron, slot) do
    cron_id = cron.id

    with {:ok, %{} = previous} <- Board.latest_cron_task(cron.id, load: :group),
         true <- close?(cron, previous.cron_run_at, slot) do
      case previous.group do
        nil -> start_group!(cron, previous).id
        %{cron_id: ^cron_id, id: id} -> id
        _theirs -> nil
      end
    else
      _apart -> nil
    end
  end

  defp close?(cron, previous, slot) do
    DateTime.diff(slot, previous, :minute) <= @group_gap_minutes and
      local_date(previous, cron) == local_date(slot, cron)
  end

  defp local_date(moment, cron),
    do: moment |> DateTime.shift_zone!(cron.timezone) |> DateTime.to_date()

  # The second close run: a group named for the cron and the day, the first run in it.
  defp start_group!(cron, previous) do
    day =
      previous.cron_run_at
      |> DateTime.shift_zone!(cron.timezone)
      |> Calendar.strftime("%a %d %b")

    group = Board.create_cron_task_group!(%{name: "#{cron.name} · #{day}", cron_id: cron.id})
    Board.group_task!(previous, group.id)
    group
  end

  defp create_task(cron, slot, group_id) do
    Board.create_cron_task(%{
      title: "#{cron.name} · #{run_date(cron, slot)}",
      description: cron.description,
      repository: cron.repository,
      workflow_id: cron.workflow_id,
      cron_id: cron.id,
      cron_run_at: slot,
      group_id: group_id
    })
  end

  # The slot on the cron's own clock: its day, and the time too when it runs on an
  # expression (several runs a day): "Wed 28 Oct", "Wed 28 Oct 14:30".
  defp run_date(cron, slot) do
    format = if cron.mode == :expression, do: "%a %d %b %H:%M", else: "%a %d %b"
    slot |> DateTime.shift_zone!(cron.timezone) |> Calendar.strftime(format)
  end

  # A task that didn't start stays in backlog, CRON-tagged, for a person to see why.
  defp failed!(cron, task, reason) do
    workflow = Workflows.get_workflow!(cron.workflow_id)
    Recurring.record_cron_run!(cron, %{last_error: reason})

    Notifications.notify!(%{
      task_id: task && task.id,
      kind: :cron_failed,
      title: "Cron “#{cron.name}” didn't start “#{workflow.name}”",
      body: reason
    })

    {:error, reason}
  end
end
