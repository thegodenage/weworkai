defmodule Weworkai.Agents.SessionPoller do
  @moduledoc """
  Polls connectors once per tick for whatever LiveViews watch and sends each watcher the
  result, so bridge load grows with watched agents, not with open tabs.
  """
  use GenServer

  require Logger

  alias Weworkai.{Agents, Connectors}

  @watchers Weworkai.Agents.SessionWatchers
  @interval_ms 2_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The caller receives `{:runs, runs, statuses}` every tick. Each run carries when its
  session last wrote anything as `:last_event_at` metadata (`Ash.Resource.get_metadata/2`),
  nil when that is unknown.
  """
  def watch_runs, do: watch(:runs, nil)

  @doc "The caller receives `{:session, session_id, result}` every tick."
  def watch_session(connector, session_id), do: watch({:session, session_id}, connector)

  def unwatch_session(session_id), do: Registry.unregister(@watchers, {:session, session_id})

  defp watch(key, connector) do
    {:ok, _} = Registry.register(@watchers, key, connector)
    GenServer.cast(__MODULE__, {:poll, key, connector})
  end

  @impl true
  def init(nil) do
    # An interval, not a timer re-armed per tick: gen_server drops a message whose module
    # is unloaded (a dev code reload), and a dropped re-arming tick stops ticking for good.
    {:ok, _timer} = :timer.send_interval(@interval_ms, :tick)
    {:ok, nil}
  end

  @impl true
  def handle_cast({:poll, key, connector}, state) do
    survive(fn -> poll(key, connector) end)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    # ponytail: polls keys one after another; parallelize with Task.async_stream if many agents make a tick slow
    @watchers
    |> Registry.select([{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Map.new()
    |> Enum.each(fn {key, connector} -> survive(fn -> poll(key, connector) end) end)

    skip_queued_ticks()
    {:noreply, state}
  end

  # A poll that raises (a dev code reload taking a module away mid-call, the database
  # restarting) is logged and retried next tick, instead of a crash loop that takes the
  # application's supervisor, and the app, down with it.
  defp survive(poll) do
    poll.()
  catch
    kind, reason ->
      Logger.error(
        "SessionPoller: a poll raised\n" <> Exception.format(kind, reason, __STACKTRACE__)
      )
  end

  # A slow tick (a bridge that takes long to answer) lets later ticks queue up; one covers them.
  defp skip_queued_ticks do
    receive do
      :tick -> skip_queued_ticks()
    after
      0 -> :ok
    end
  end

  defp poll(:runs, nil) do
    active = Agents.active_runs!()
    sessions = fetch_sessions(active)

    runs =
      Enum.map(
        active,
        &Ash.Resource.put_metadata(&1, :last_event_at, sessions[&1.id].last_event_at)
      )

    statuses = Map.new(sessions, fn {id, session} -> {id, session.status} end)
    dispatch(:runs, {:runs, runs, statuses})
  end

  defp poll({:session, session_id} = key, connector) do
    dispatch(key, {:session, session_id, Connectors.session(connector, session_id)})
  end

  defp dispatch(key, message) do
    Registry.dispatch(@watchers, key, fn entries ->
      Enum.each(entries, fn {pid, _connector} -> send(pid, message) end)
    end)
  end

  # One listing per connector; a run whose session is gone, or whose connector was removed
  # (nothing can ask about it any more), has ended.
  defp fetch_sessions(runs) do
    {connected, disconnected} = Enum.split_with(runs, & &1.agent.connector_link)

    connected
    |> Enum.group_by(& &1.agent.connector_link.connector)
    |> Enum.flat_map(fn {connector, connector_runs} ->
      case Connectors.list_sessions(connector) do
        {:ok, sessions} ->
          by_id = Map.new(sessions, &{&1.id, &1})
          Enum.map(connector_runs, &{&1.id, Map.get(by_id, &1.session_id, unknown(:ended))})

        {:error, _message} ->
          Enum.map(connector_runs, &{&1.id, unknown(:unreachable)})
      end
    end)
    |> Enum.concat(Enum.map(disconnected, &{&1.id, unknown(:ended)}))
    |> Map.new()
  end

  defp unknown(status), do: %{status: status, last_event_at: nil}
end
