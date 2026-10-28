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

  # Five fields, however far apart; a sixth would be read as a year (`0 0 9 * * *` is not
  # 9:00 daily but midnight on the 9th), so it is refused, as is `@reboot`, which parses
  # but has no dates.
  defp parse(expression) do
    fields = String.split(expression)

    case Parser.parse(Enum.join(fields, " ")) do
      {:ok, %{reboot: true}} ->
        {:error, "@reboot is not supported"}

      {:ok, parsed} ->
        if special?(fields) or length(fields) == 5,
          do: {:ok, parsed},
          else: {:error, "needs five fields: minute hour day-of-month month weekday"}

      {:error, _message} ->
        {:error, "is not a valid cron expression"}
    end
  end

  defp special?([<<"@", _rest::binary>>]), do: true
  defp special?(_fields), do: false

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

  @doc """
  Fires every cron due as of `now`, for its newest slot that has come, if that is within
  the grace window; older slots are skipped, the first of them recorded. One that raises
  leaves the others be.
  """
  def start_due(now \\ DateTime.utc_now()) do
    Enum.each(Recurring.due_crons!(now), fn cron ->
      try do
        catch_up(cron, now)
      rescue
        error ->
          Logger.error(
            "Recurring: cron #{cron.id} raised\n" <>
              Exception.format(:error, error, __STACKTRACE__)
          )
      end
    end)
  end

  defp catch_up(cron, now) do
    missed = cron.next_run_at
    window = DateTime.add(now, -@grace_minutes, :minute)

    # Its first slot within the window; walking from a slot older than that could take
    # long (a minutely cron down for days).
    first =
      if DateTime.compare(missed, window) == :lt,
        do: next_run(cron, DateTime.add(window, -1, :second)),
        else: missed

    case first && DateTime.compare(first, now) != :gt && newest_slot(cron, first, now) do
      %DateTime{} = slot when slot == missed ->
        start(cron, now, slot)

      %DateTime{} = slot ->
        fire(cron, now, slot, %{last_skipped_at: missed})

      _none_come ->
        Recurring.claim_cron!(cron, %{next_run_at: first, last_skipped_at: missed})
    end
  end

  # The last slot from `slot` on that has come by `now`.
  defp newest_slot(cron, slot, now) do
    case next_run(cron, slot) do
      %DateTime{} = next ->
        if DateTime.compare(next, now) == :gt, do: slot, else: newest_slot(cron, next, now)

      nil ->
        slot
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
  def start(cron, now \\ DateTime.utc_now(), slot \\ nil),
    do: fire(cron, now, slot || now, missed_seen(cron))

  defp fire(cron, now, slot, claim) do
    cron =
      Recurring.claim_cron!(
        cron,
        Map.merge(%{last_run_at: now, next_run_at: next_slot(cron, now)}, claim)
      )

    with {:ok, task} <- create_task(cron, slot) do
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
  # twenty cards. A run a person put in a group of their own, or took out of one (`apart`),
  # starts none, and the day's runs after it stay apart too.
  defp grouping(cron, slot) do
    cron_id = cron.id

    with {:ok, %{} = previous} <- Board.latest_cron_task(cron.id, load: :group),
         true <- close?(cron, previous.cron_run_at, slot) do
      case previous.group do
        nil when previous.apart -> :apart
        nil -> {:start, previous}
        %{cron_id: ^cron_id, id: id} -> {:join, id}
        _theirs -> :none
      end
    else
      _far -> :none
    end
  end

  defp close?(cron, previous, slot) do
    DateTime.diff(slot, previous, :minute) <= @group_gap_minutes and
      local_date(previous, cron) == local_date(slot, cron)
  end

  defp local_date(moment, cron),
    do: moment |> DateTime.shift_zone!(cron.timezone) |> DateTime.to_date()

  # The group is started only once the new run exists, so a run that fails to be created
  # leaves the one before it as it was.
  defp create_task(cron, slot) do
    grouping = grouping(cron, slot)

    attrs = %{
      title: "#{cron.name} · #{run_date(cron, slot)}",
      description: cron.description,
      repository: cron.repository,
      workflow_id: cron.workflow_id,
      cron_id: cron.id,
      cron_run_at: slot,
      cron_timezone: cron.timezone,
      group_id: with({:join, id} <- grouping, do: id, else: (_ -> nil)),
      apart: grouping == :apart
    }

    with {:ok, task} <- Board.create_cron_task(attrs) do
      case grouping do
        {:start, previous} -> start_group(cron, previous, task)
        _other -> {:ok, task}
      end
    end
  end

  # The second close run: a group named for the cron and the day, both runs in it.
  defp start_group(cron, previous, task) do
    day =
      previous.cron_run_at
      |> DateTime.shift_zone!(cron.timezone)
      |> Calendar.strftime("%a %d %b")

    group = Board.create_cron_task_group!(%{name: "#{cron.name} · #{day}", cron_id: cron.id})
    Board.group_task!(previous, group.id)
    Board.group_task(task, group.id)
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
