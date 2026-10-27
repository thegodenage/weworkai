defmodule Weworkai.Scheduling.Scheduler do
  @moduledoc """
  The single scheduler. Every tick it starts an agent run for each due ScheduledJob; on
  every SessionPoller update it closes the attempts whose agent run finished, failed or
  was stopped. Run starts, results and failures go through `Weworkai.Workflows.Engine`, which
  moves the attempt and the board task together. Logic lives in `dispatch_due/0` and
  `sync_runs/1`. An attempt that raises fails on its own: crashing would restart the
  scheduler on the same attempt forever. See docs/scheduler.md and docs/workflow.md.
  """
  use GenServer

  require Logger

  alias Weworkai.{Agents, ErrorText, Scheduling}
  alias Weworkai.Agents.{Budget, SessionPoller}
  alias Weworkai.Scheduling.{StartFailure, Timeout}
  alias Weworkai.Workflows.Engine

  @interval_ms 1_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    SessionPoller.watch_runs()
    # An interval, not a timer re-armed per tick: gen_server drops a message whose module
    # is unloaded (a dev code reload), and a dropped re-arming tick stops ticking for good.
    {:ok, _timer} = :timer.send_interval(@interval_ms, :tick)
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, state) do
    survive("a tick", &dispatch_due/0)
    skip_queued_ticks()
    {:noreply, state}
  end

  def handle_info({:runs, runs, statuses}, state) do
    last_events = Map.new(runs, &{&1.id, Ash.Resource.get_metadata(&1, :last_event_at)})
    survive("syncing runs", fn -> sync_runs(statuses, last_events) end)
    {:noreply, state}
  end

  # What raises outside an attempt (a dev code reload taking a module away mid-call, the
  # database restarting) is logged and left to the next tick. Crashing would restart the
  # scheduler into the same error every second, until the application's supervisor gave
  # up and the whole app exited.
  defp survive(what, step) do
    step.()
  catch
    kind, reason ->
      Logger.error(
        "Scheduler: #{what} raised\n" <> Exception.format(kind, reason, __STACKTRACE__)
      )
  end

  # A slow tick (a bridge call) lets later ticks queue up; one tick covers them all.
  defp skip_queued_ticks do
    receive do
      :tick -> skip_queued_ticks()
    after
      0 -> :ok
    end
  end

  # ponytail: start_run is a blocking bridge call inside the tick; move it to a Task.Supervisor if queued jobs pile up
  def dispatch_due do
    Enum.each(Scheduling.due_scheduled_jobs!(), fn attempt ->
      isolate(attempt, &dispatch/1, fn attempt, reason ->
        Engine.start_failed(attempt, StartFailure.transient(reason))
      end)
    end)
  end

  defp dispatch(attempt) do
    job = Engine.picked_up(attempt)

    with :ok <- Budget.allow(job),
         {:ok, run} <-
           Agents.start_run(%{
             folder: job.folder,
             task: job.prompt,
             agent_id: job.agent_id,
             json_schema: job.json_schema,
             resume: job.resume,
             fork: job.fork,
             attachments: Engine.attachments(attempt.job.task)
           }) do
      record_start(attempt, run)
    else
      {:error, error} -> start_failed(attempt, error)
    end
  end

  defp start_failed(attempt, error) do
    failure = StartFailure.from_error(error)

    Logger.warning(
      "Scheduler: attempt #{attempt.id} did not start (#{failure.kind})\n" <>
        Exception.message(error)
    )

    Engine.start_failed(attempt, failure)
  end

  # A run nobody records (its job was canceled meanwhile, or recording raised) would work
  # on unwatched; it is stopped before the attempt fails, so a retry never runs beside it.
  defp record_start(attempt, run) do
    Engine.run_started(attempt, run)
  rescue
    error ->
      Agents.stop_run(run)
      reraise error, __STACKTRACE__
  end

  @doc """
  `statuses` maps active run ids to their run status. A run missing from it may have
  started after the poller's snapshot, so only a run marked stopped counts as canceled.
  `last_events` maps run ids to when their session last wrote anything: a working run
  past its job's timeouts as of `now` is stopped and retried (`Scheduling.Timeout`).
  """
  def sync_runs(statuses, last_events \\ %{}, now \\ DateTime.utc_now()) do
    Enum.each(Scheduling.started_scheduled_jobs!(), fn attempt ->
      isolate(attempt, &sync_run(&1, statuses, last_events, now), fn attempt, reason ->
        Engine.run_failed(attempt, "The run's result could not be applied: #{reason}")
      end)
    end)
  end

  defp sync_run(attempt, statuses, last_events, now) do
    case {Map.get(statuses, attempt.agent_run_id), attempt.agent_run} do
      {:done, _run} ->
        Engine.run_done(attempt)

      {:failed, _run} ->
        Engine.run_failed(attempt, "The agent run failed; see its log.")

      {:ended, _run} ->
        Engine.run_failed(attempt, "The bridge no longer knows this agent run.")

      # Marks the run stopped first, so canceling the job doesn't ask the bridge to stop it.
      {:stopped, run} ->
        Agents.stop_run!(run)
        Scheduling.cancel_job!(attempt.job)

      {nil, %{stopped_at: %DateTime{}}} ->
        Scheduling.cancel_job!(attempt.job)

      {:working, run} ->
        case Timeout.exceeded(attempt.job, run.inserted_at, last_events[run.id], now) do
          nil -> :ok
          timeout -> Engine.run_timed_out(attempt, timeout)
        end

      _running ->
        :ok
    end
  end

  defp isolate(attempt, step, fail) do
    step.(attempt)
  rescue
    error ->
      Logger.error(
        "Scheduler: attempt #{attempt.id} raised\n" <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      give_up(attempt, ErrorText.readable(error), fail)
  end

  defp give_up(attempt, reason, fail) do
    fail.(attempt, reason)
  rescue
    error ->
      Logger.error("Scheduler: could not fail attempt #{attempt.id}: #{Exception.message(error)}")
  end
end
