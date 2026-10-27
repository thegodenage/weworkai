defmodule Weworkai.Audit.Timeline do
  @moduledoc """
  A task's history as a Gantt chart, in the manner of Temporal's timeline view: a lane per
  workflow block (or per agent) with a bar per job, queued and then running, and the
  human steps as points between them. Stretches no workflow job covers are time the task
  waited on people. Positions are percentages of the task's span, so the page draws the
  chart without JavaScript. Read from the task's jobs (`Job.node_id`, `started_at`,
  `finished_at`) and its `Board.TaskEvent`s; what the runs used from the cost ledger
  (`Agents.RunUsage`), per bar and in the totals.
  """
  alias Weworkai.{Agents, Board, Scheduling, Workflows}
  alias Weworkai.Agents.Agent.Role
  alias Weworkai.Agents.Usage
  alias Weworkai.Scheduling.Job.Stage
  alias Weworkai.Workflows.Graph

  @active [:before_start, :on_start, :in_progress]

  # Tick spacings in seconds: the first that leaves at most @max_ticks ticks is drawn.
  @tick_steps [1, 5, 15, 30, 60, 300, 900, 1_800, 3_600, 10_800, 21_600, 43_200, 86_400, 604_800]
  @max_ticks 6

  # A shorter gap is the engine moving on, not anyone waiting.
  @min_wait_ms 1_000

  defstruct [
    :from,
    :to,
    live?: false,
    lanes: [],
    points: [],
    waits: [],
    ticks: [],
    breakdown: [],
    totals: %{}
  ]

  @type t :: %__MODULE__{}

  @doc """
  The timeline of `task` as of `now`, a lane per block (`:block`) or per agent (`:agent`).
  `from` is nil while nothing happened on the task yet. While the task is in the works
  (not in backlog, done or canceled) the chart runs up to now.
  """
  @spec build(Ash.Resource.record(), :block | :agent, DateTime.t()) :: t()
  def build(task, group \\ :block, now \\ DateTime.utc_now()) do
    graph = Workflows.running!(task).graph
    usages = Map.new(Agents.task_usage!(task.id), &{&1.agent_run_id, &1})
    bars = task.id |> Scheduling.task_jobs!() |> Enum.map(&bar(&1, graph, usages, now))
    events = Board.list_events!(task.id)
    live? = task.status not in [:backlog, :done, :canceled]

    case Enum.flat_map(bars, &[&1.queued_at, &1.ended_at]) ++ Enum.map(events, & &1.inserted_at) do
      [] ->
        %__MODULE__{live?: live?}

      times ->
        timeline = chart(bars, events, span(times, live?, now), group, live?)
        usage = Usage.total(Map.values(usages))
        %{timeline | totals: Map.put(timeline.totals, :usage, usage)}
    end
  end

  @doc "The bar of the job with `id`; nil when there is none."
  def bar(_timeline, nil), do: nil

  def bar(timeline, id),
    do: Enum.find_value(timeline.lanes, fn lane -> Enum.find(lane.bars, &(&1.id == id)) end)

  @doc "Milliseconds the way the timeline writes them: 0s, 42s, 3m 12s, 2h 5m, 3d 4h."
  def duration(ms) when ms < 60_000, do: "#{div(ms, 1_000)}s"
  def duration(ms) when ms < 3_600_000, do: units(ms, 60_000, "m", 1_000, "s")
  def duration(ms) when ms < 86_400_000, do: units(ms, 3_600_000, "h", 60_000, "m")
  def duration(ms), do: units(ms, 86_400_000, "d", 3_600_000, "h")

  defp units(ms, major, major_unit, minor, minor_unit) do
    case div(rem(ms, major), minor) do
      0 -> "#{div(ms, major)}#{major_unit}"
      rest -> "#{div(ms, major)}#{major_unit} #{rest}#{minor_unit}"
    end
  end

  defp span(times, live?, now) do
    from = Enum.min(times, DateTime)
    to = if live?, do: now, else: Enum.max(times, DateTime)
    # At least a second, so a chart of one instant still has a width to divide.
    {from, Enum.max([to, DateTime.add(from, 1, :second)], DateTime)}
  end

  defp chart(bars, events, {from, to}, group, live?) do
    span_ms = ms(from, to)
    at = fn time -> pct(ms(from, time), span_ms) end
    bars = Enum.map(bars, &place(&1, at))
    lanes = lanes(bars, group)

    waits =
      for {start, stop} <- waits(bars, from, to), ms(start, stop) >= @min_wait_ms do
        %{left: at.(start), width: Float.round(at.(stop) - at.(start), 3), ms: ms(start, stop)}
      end

    waiting_ms = sum(waits, :ms)

    %__MODULE__{
      from: from,
      to: to,
      live?: live?,
      lanes: lanes,
      points: Enum.map(events, &point(&1, at)),
      waits: waits,
      ticks: ticks(span_ms),
      breakdown: breakdown(lanes, waiting_ms),
      totals: %{
        wall_ms: span_ms,
        running_ms: sum(bars, :running_ms),
        queued_ms: sum(bars, :queued_ms),
        waiting_ms: waiting_ms,
        runs: length(bars),
        human_steps: length(events)
      }
    }
  end

  defp bar(job, graph, usages, now) do
    %{
      id: job.id,
      node_id: job.node_id,
      stage: job.stage,
      status: job.status,
      block: block_label(job, graph),
      employee: job.agent.employee,
      role: job.agent.role,
      queued_at: job.inserted_at,
      started_at: job.started_at,
      ended_at: ended_at(job, now),
      live?: job.status in @active,
      attempts: length(job.scheduled_jobs),
      run_id: run_id(job.scheduled_jobs),
      usage:
        Usage.total(
          for attempt <- job.scheduled_jobs,
              usage = usages[attempt.agent_run_id],
              do: usage
        )
    }
  end

  defp ended_at(%{finished_at: %DateTime{} = at}, _now), do: at
  defp ended_at(%{status: status}, now) when status in @active, do: now
  # On hold: it stopped where it last changed.
  defp ended_at(job, _now), do: job.updated_at

  # The newest attempt that started a run: its log is the job's.
  defp run_id(attempts) do
    attempts
    |> Enum.filter(& &1.agent_run_id)
    |> Enum.max_by(& &1.inserted_at, DateTime, fn -> %{agent_run_id: nil} end)
    |> Map.fetch!(:agent_run_id)
  end

  defp place(bar, at) do
    started = bar.started_at || bar.ended_at

    Map.merge(bar, %{
      left: at.(bar.queued_at),
      width: Float.round(at.(bar.ended_at) - at.(bar.queued_at), 3),
      queued_ms: ms(bar.queued_at, started),
      running_ms: if(bar.started_at, do: ms(bar.started_at, bar.ended_at), else: 0)
    })
  end

  defp point(event, at) do
    %{
      id: event.id,
      kind: event.kind,
      label: event.label,
      at: event.inserted_at,
      left: at.(event.inserted_at)
    }
  end

  defp lanes(bars, :block) do
    bars
    |> Enum.group_by(&block_key/1)
    |> Enum.map(fn {key, [first | _] = bars} ->
      lane(lane_id(key), first.block, names(bars), nil, bars)
    end)
    |> by_first_bar()
  end

  defp lanes(bars, :agent) do
    bars
    |> Enum.group_by(& &1.employee.id)
    |> Enum.map(fn {id, [first | _] = bars} ->
      lane(id, first.employee.name, Role.label(first.role), first.employee, bars)
    end)
    |> by_first_bar()
  end

  defp lane(id, label, sublabel, employee, bars) do
    %{
      id: id,
      label: label,
      sublabel: sublabel,
      employee: employee,
      bars: bars,
      running_ms: sum(bars, :running_ms)
    }
  end

  defp by_first_bar(lanes), do: Enum.sort_by(lanes, &hd(&1.bars).queued_at, DateTime)

  defp names(bars), do: bars |> Enum.map(& &1.employee.name) |> Enum.uniq() |> Enum.join(", ")

  defp block_key(%{stage: :ask}), do: :ask
  defp block_key(%{node_id: nil, stage: stage}), do: {:stage, stage}
  defp block_key(%{node_id: id}), do: id

  defp lane_id(:ask), do: "questions"
  defp lane_id({:stage, stage}), do: "stage-#{stage || "custom"}"
  defp lane_id(id), do: id

  defp block_label(%{stage: :ask}, _graph), do: "Questions"
  defp block_label(%{node_id: nil, stage: nil}, _graph), do: "Agent"
  defp block_label(%{node_id: nil, stage: stage}, _graph), do: Stage.label(stage)

  defp block_label(%{node_id: id}, graph) do
    case Graph.node(graph, id) do
      nil -> "Removed block"
      node -> node.label
    end
  end

  # The stretches between from and to no workflow job covers (questions run beside it).
  defp waits(bars, from, to) do
    {cursor, gaps} =
      bars
      |> Enum.reject(&(&1.stage == :ask))
      |> Enum.sort_by(& &1.queued_at, DateTime)
      |> Enum.reduce({from, []}, fn bar, {cursor, gaps} ->
        gaps = if later?(bar.queued_at, cursor), do: [{cursor, bar.queued_at} | gaps], else: gaps
        {Enum.max([cursor, bar.ended_at], DateTime), gaps}
      end)

    Enum.reverse(if later?(to, cursor), do: [{cursor, to} | gaps], else: gaps)
  end

  defp ticks(span_ms) do
    step = Enum.find(@tick_steps, List.last(@tick_steps), &(span_ms / (&1 * 1_000) <= @max_ticks))
    for ms <- 0..span_ms//(step * 1_000), do: %{left: pct(ms, span_ms), label: duration(ms)}
  end

  # Where the time went, longest first: each lane's agent time (queued and running), and the
  # time the task waited on people.
  defp breakdown(lanes, waiting_ms) do
    lane_rows =
      for lane <- lanes do
        queued = sum(lane.bars, :queued_ms)

        %{
          id: lane.id,
          label: lane.label,
          kind: :lane,
          stage: hd(lane.bars).stage,
          ms: lane.running_ms + queued,
          running_ms: lane.running_ms
        }
      end

    waiting = %{
      id: "waiting",
      label: "Waiting on people",
      kind: :waiting,
      stage: nil,
      ms: waiting_ms,
      running_ms: 0
    }

    rows = (lane_rows ++ [waiting]) |> Enum.filter(&(&1.ms > 0)) |> Enum.sort_by(& &1.ms, :desc)
    longest = rows |> Enum.map(& &1.ms) |> Enum.max(fn -> 1 end)

    Enum.map(rows, fn row ->
      Map.merge(row, %{width: pct(row.ms, longest), running_share: pct(row.running_ms, row.ms)})
    end)
  end

  defp later?(a, b), do: DateTime.compare(a, b) == :gt
  defp ms(from, to), do: max(DateTime.diff(to, from, :millisecond), 0)
  defp pct(part, whole), do: Float.round(min(part * 100 / whole, 100.0), 3)
  defp sum(items, key), do: items |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum()
end
