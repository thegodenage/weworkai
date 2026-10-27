defmodule Weworkai.Agents.SessionPollerTest do
  use Weworkai.DataCase, async: false

  alias Weworkai.Agents.SessionPoller

  test "the poller keeps ticking after a tick lands while its code is reloaded" do
    # The application's poller: its name is fixed, so a second one can't be started here.
    pid = Process.whereis(SessionPoller)
    beam = List.to_string(:code.which(SessionPoller))

    on_exit(fn ->
      if File.exists?(beam <> ".reloading"), do: File.rename!(beam <> ".reloading", beam)
      Code.ensure_loaded!(SessionPoller)
    end)

    # A dev code reload purges the module and removes its beam until the new one is
    # written; gen_server silently drops a message whose callback module can't be loaded.
    # Purging kills a process inside the module, so the poller (maybe mid-poll) is
    # suspended between messages first.
    send(pid, :tick)
    :ok = :sys.suspend(pid)
    File.rename!(beam, beam <> ".reloading")
    :code.delete(SessionPoller)
    :code.purge(SessionPoller)
    :erlang.trace(pid, true, [:receive])
    :ok = :sys.resume(pid)
    assert_receive {:trace, ^pid, :receive, :tick}, 3_000
    :erlang.trace(pid, false, [:receive])
    _ = :sys.get_state(pid)
    File.rename!(beam <> ".reloading", beam)
    Code.ensure_loaded!(SessionPoller)

    # Registered directly: watch_runs/0 also polls once right away, which needs no tick.
    {:ok, _} = Registry.register(Weworkai.Agents.SessionWatchers, :runs, nil)
    assert_receive {:runs, [], %{}}, 5_000
  end

  test "a poll that calls a module a code reload took away is logged; polling goes on" do
    pid = Process.whereis(SessionPoller)
    ref = Process.monitor(pid)
    beam = List.to_string(:code.which(Weworkai.Agents))

    restore = fn ->
      if File.exists?(beam <> ".reloading"), do: File.rename!(beam <> ".reloading", beam)
      Code.ensure_loaded!(Weworkai.Agents)
    end

    on_exit(restore)
    {:ok, _} = Registry.register(Weworkai.Agents.SessionWatchers, :runs, nil)
    # Suspended between messages, so the purge can't catch it inside the module.
    :ok = :sys.suspend(pid)
    File.rename!(beam, beam <> ".reloading")
    :code.delete(Weworkai.Agents)
    :code.purge(Weworkai.Agents)
    :ok = :sys.resume(pid)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(pid, :tick)
        _ = :sys.get_state(pid)
      end)

    restore.()
    assert log =~ "SessionPoller: a poll raised"
    assert_receive {:runs, [], %{}}, 5_000
    refute_received {:DOWN, ^ref, :process, ^pid, _reason}
  end
end
