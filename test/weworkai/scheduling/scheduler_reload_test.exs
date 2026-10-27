defmodule Weworkai.Scheduling.SchedulerReloadTest do
  use Weworkai.DataCase, async: false

  import ExUnit.CaptureLog

  alias Weworkai.Scheduling
  alias Weworkai.Scheduling.Scheduler

  # A dev code reload purges a module and removes its beam until the new one is written;
  # a tick calling it meanwhile raises UndefinedFunctionError. Crashing on it restarted the
  # scheduler into the same error every second, until the application's supervisor gave up
  # and the whole app exited.
  test "a tick that calls a module a code reload took away is logged, and ticking goes on" do
    pid = start_supervised!(Scheduler)
    ref = Process.monitor(pid)
    beam = List.to_string(:code.which(Scheduling))

    restore = fn ->
      if File.exists?(beam <> ".reloading"), do: File.rename!(beam <> ".reloading", beam)
      Code.ensure_loaded!(Scheduling)
    end

    on_exit(restore)

    # Suspended between messages, so the purge can't catch it inside the module (which
    # would kill it); its first poller update may arrive any moment.
    :ok = :sys.suspend(pid)
    File.rename!(beam, beam <> ".reloading")
    :code.delete(Scheduling)
    :code.purge(Scheduling)
    :ok = :sys.resume(pid)

    log =
      capture_log(fn ->
        send(pid, :tick)
        _ = :sys.get_state(pid)
      end)

    restore.()

    assert log =~ "Scheduler: a tick raised"
    assert log =~ "UndefinedFunctionError"
    send(pid, :tick)
    _ = :sys.get_state(pid)
    refute_received {:DOWN, ^ref, :process, ^pid, _reason}
  end
end
