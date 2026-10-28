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
  (DST) runs when they resume; one they pass twice runs the first time, unless the
  expression runs every hour (a `*` hour), which goes on through the repeated hour too.
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
    |> Stream.map(&(&1 |> moments(schedule.at, schedule.timezone) |> hd()))
    |> Enum.find(&(DateTime.compare(&1, from) == :gt))
    |> DateTime.shift_zone!("Etc/UTC")
  end

  # The expression is matched on the local clock from `from`'s own minute, keeping the
  # first moment after `from`: a local time the clocks pass twice is two moments, the
  # second taken only by an every-hour expression. With both a day of the month and a
  # weekday given, either matching will do (as cron has it): the earlier of the two.
  defp next_match(%{alternatives: alternatives, every_hour?: every_hour?}, timezone, from) do
    local_from = from |> DateTime.shift_zone!(timezone) |> DateTime.to_naive()
    start = %{local_from | second: 0, microsecond: {0, 0}}

    # Within a repeated hour, the earlier local times of it are still to come a second time.
    start =
      if length(moments(NaiveDateTime.to_date(start), NaiveDateTime.to_time(start), timezone)) ==
           2,
         do: NaiveDateTime.add(start, -3600),
         else: start

    alternatives
    |> Enum.map(&match_from(&1, every_hour?, timezone, from, start))
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  # A second moment of a repeated hour comes after the first moments of the later times in
  # that hour: the search goes on until a match's first moment is past the best one found.
  defp match_from(expression, every_hour?, timezone, from, start, best \\ nil) do
    case Crontab.Scheduler.get_next_run_date(expression, start) do
      {:ok, naive} ->
        [first | _] =
          moments = moments(NaiveDateTime.to_date(naive), NaiveDateTime.to_time(naive), timezone)

        if best && DateTime.compare(first, best) != :lt do
          DateTime.shift_zone!(best, "Etc/UTC")
        else
          moments = if every_hour?, do: moments, else: [first]
          found = Enum.find(moments, &(DateTime.compare(&1, from) == :gt))
          best = Enum.min([best, found] |> Enum.reject(&is_nil/1), DateTime, fn -> nil end)
          match_from(expression, every_hour?, timezone, from, NaiveDateTime.add(naive, 60), best)
        end

      {:error, _never} ->
        best && DateTime.shift_zone!(best, "Etc/UTC")
    end
  end

  # The moments a local time is: one, two when the clocks pass it twice, or when they skip
  # it, the one they resume at.
  defp moments(date, time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, datetime} -> [datetime]
      {:ambiguous, first, second} -> [first, second]
      {:gap, _before, resumed} -> [resumed]
    end
  end

  @specials ~w(@yearly @annually @monthly @weekly @daily @midnight @hourly)

  # Five fields, however far apart, or one of cron's @ names. A sixth field would be read
  # as a year (`0 0 9 * * *` is not 9:00 daily but midnight on the 9th), and a range that
  # runs backwards (`30-10`) as every value, so both are refused.
  defp parse(expression) do
    fields = String.split(expression)

    with :ok <- check_fields(fields),
         {:ok, parsed} <- crontab(Enum.join(fields, " ")),
         :ok <- check_ranges(parsed) do
      {:ok, compile(parsed)}
    end
  end

  defp check_fields([<<"@", _rest::binary>> = special]) do
    if special in @specials, do: :ok, else: {:error, "#{special} is not supported"}
  end

  defp check_fields(fields) when length(fields) == 5, do: :ok
  defp check_fields(fields) when length(fields) > 5, do: {:error, five_fields()}
  defp check_fields(_fields), do: {:error, "is not a valid cron expression"}

  defp five_fields, do: "needs five fields: minute hour day-of-month month weekday"

  defp crontab(text) do
    case Parser.parse(text) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _message} -> {:error, "is not a valid cron expression"}
    end
  end

  defp check_ranges(parsed) do
    backwards? =
      [parsed.minute, parsed.hour, parsed.day, parsed.month, parsed.weekday]
      |> List.flatten()
      |> Enum.any?(fn
        {:-, low, high} when is_integer(low) and is_integer(high) -> low > high
        {:/, {:-, low, high}, _step} when is_integer(low) and is_integer(high) -> low > high
        _value -> false
      end)

    if backwards?, do: {:error, "has a range that runs backwards"}, else: :ok
  end

  # crontab counts a `*/n` step in the day and month fields from 0; cron counts from 1
  # (`*/3` months: Jan, Apr, Jul, Oct).
  defp compile(parsed) do
    expression = %{
      parsed
      | day: Enum.map(parsed.day, &from_one(&1, 31)),
        month: Enum.map(parsed.month, &from_one(&1, 12))
    }

    alternatives =
      if star?(parsed.day) or star?(parsed.weekday),
        do: [expression],
        else: [%{expression | weekday: [:*]}, %{expression | day: [:*]}]

    %{alternatives: alternatives, every_hour?: star?(parsed.hour)}
  end

  defp from_one({:/, :*, step}, last), do: {:/, {:-, 1, last}, step}
  defp from_one(value, _last), do: value

  # A field cron reads as unrestricted: `*`, or a step over `*`.
  defp star?([:*]), do: true
  defp star?([{:/, :*, _step}]), do: true
  defp star?(_values), do: false

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
        claim(cron, %{next_run_at: first, last_skipped_at: missed})
    end
  end

  # `:taken` when another run (a tick, a Run now) or an edit got to the cron first.
  defp claim(cron, attrs) do
    case Recurring.claim_cron(cron, attrs) do
      {:ok, cron} -> {:ok, cron}
      {:error, _stale} -> :taken
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
    attrs = Map.merge(%{last_run_at: now, next_run_at: next_slot(cron, now)}, claim)

    with {:ok, cron} <- claim(cron, attrs),
         {:ok, task} <- create_task(cron, slot) do
      case Board.move_task(task, :todo) do
        {:ok, started} ->
          Recurring.record_cron_run!(cron, %{last_error: nil})
          {:ok, started}

        {:error, error} ->
          failed!(cron, task, ErrorText.readable(error))
      end
    else
      :taken -> {:error, "it has just run or changed; try again"}
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
        {:start, previous} -> {:ok, start_group(cron, previous, task)}
        _other -> {:ok, task}
      end
    end
  end

  # The second close run: a group named for the cron and the day, both runs in it. Only a
  # nicety: when it can't be made (the previous run was just deleted…), the new run goes on
  # ungrouped, and still starts.
  defp start_group(cron, previous, task) do
    day =
      previous.cron_run_at
      |> DateTime.shift_zone!(cron.timezone)
      |> Calendar.strftime("%a %d %b")

    with {:ok, group} <-
           Board.create_cron_task_group(%{name: "#{cron.name} · #{day}", cron_id: cron.id}),
         {:ok, _previous} <- grouped(previous, group),
         {:ok, grouped} <- Board.group_task(task, group.id) do
      grouped
    else
      {:error, error} ->
        Logger.warning("Recurring: cron #{cron.id} didn't group its runs: #{inspect(error)}")
        task
    end
  rescue
    error ->
      Logger.warning("Recurring: cron #{cron.id} didn't group its runs: #{inspect(error)}")
      task
  end

  # A group the previous run couldn't join is dropped again.
  defp grouped(previous, group) do
    with {:error, error} <- Board.group_task(previous, group.id) do
      Board.destroy_task_group(group)
      {:error, error}
    end
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
      title: "Cron “#{clip(cron.name, 120)}” didn't start “#{clip(workflow.name, 120)}”",
      body: reason
    })

    {:error, reason}
  end

  # Within the notification title's 300 characters, whatever the names.
  defp clip(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end
end
