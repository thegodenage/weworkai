defmodule Weworkai.Scheduling.SchedulerTest do
  use Weworkai.DataCase, async: false

  # Start failures are logged with their full detail.
  @moduletag :capture_log

  import ExUnit.CaptureLog

  require Ash.Query

  alias Weworkai.{Agents, Board, Connectors, Notifications, Organization, Scheduling}
  alias Weworkai.Agents.SessionPoller
  alias Weworkai.Connectors.ClaudeBridge
  alias Weworkai.Scheduling.{Scheduler, ScheduledJob}

  defp agent_task do
    connector = Connectors.create_connector!(%{name: "Claude", provider: :claude_code})

    employee =
      Organization.create_employee!(%{
        kind: :agent,
        name: "Ada",
        agent_role: :coder,
        connector_id: connector.id
      })

    # Skips :configure, whose check would ask the bridge for its model list.
    employee.agent_id
    |> Agents.get_agent!()
    |> Ash.Changeset.for_update(:assign_role, %{role: :coder})
    |> Ash.Changeset.force_change_attributes(%{model: "claude-opus-5-5"})
    |> Ash.update!()

    %{title: "Add login", description: "Email + password"}
    |> Board.create_task!()
    |> Board.advance_task!(%{assignee_id: employee.id})
  end

  defp stub_bridge(start_result) do
    test = self()

    Req.Test.stub(ClaudeBridge, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/sessions"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:started, JSON.decode!(body)})

          case start_result do
            :ok ->
              Req.Test.json(conn, %{
                "id" => "abcd1234",
                "claudeSessionId" => "0b5e7f0e-3c1a-4d2b-9f6e-2a7c8d9e1f00"
              })

            :unavailable ->
              conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "bridge down"})

            :rejected ->
              conn
              |> Plug.Conn.put_status(422)
              |> Req.Test.json(%{"error" => "~/app is not a folder on this computer"})
          end

        {"GET", "/sessions/abcd1234"} ->
          Req.Test.json(conn, %{
            "id" => "abcd1234",
            "status" => "done",
            "output" => "",
            "result" => "Added login.",
            "structured" => nil,
            "claudeSessionId" => "0b5e7f0e-3c1a-4d2b-9f6e-2a7c8d9e1f00"
          })

        {"POST", "/sessions/abcd1234/stop"} ->
          Req.Test.json(conn, %{"id" => "abcd1234"})
      end
    end)
  end

  defp job_attrs(task, attrs \\ %{}) do
    Map.merge(
      %{
        task_id: task.id,
        agent_id: task.assignee.agent_id,
        folder: "~/app",
        prompt: "#{task.title}\n\n#{task.description}"
      },
      attrs
    )
  end

  defp attempts(job) do
    ScheduledJob
    |> Ash.Query.filter(job_id == ^job.id)
    |> Ash.Query.sort(attempt: :asc)
    |> Ash.read!()
  end

  defp job_status(job), do: Scheduling.get_job!(job.id).status

  # Skips the backoff wait; no action may move run_at.
  defp make_due(attempt) do
    Repo.update_all(
      from(s in "scheduled_jobs", where: s.id == type(^attempt.id, Ecto.UUID)),
      set: [run_at: DateTime.utc_now()]
    )
  end

  defp connector_id(job) do
    Agents.get_agent!(job.agent_id, load: :connector_link).connector_link.connector_id
  end

  defp started_job do
    stub_bridge(:ok)
    job = Scheduling.create_job!(job_attrs(agent_task()))
    Scheduler.dispatch_due()
    [attempt] = attempts(job)
    {job, attempt}
  end

  test "creating a job queues its first attempt; a chained job waits" do
    task = agent_task()
    first = Scheduling.create_job!(job_attrs(task))
    second = Scheduling.create_job!(job_attrs(task, %{previous_job_id: first.id}))

    assert [%{state: :pending, attempt: 1}] = attempts(first)
    assert attempts(second) == []
  end

  test "a job needs an agent and a prompt" do
    task = Board.create_task!(%{title: "Nobody"})

    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.create_job(%{task_id: task.id, folder: "~/app", prompt: "Go"})

    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.create_job(%{
               task_id: task.id,
               agent_id: agent_task().assignee.agent_id,
               folder: "~/app"
             })
  end

  test "dispatching a due attempt starts the agent run on the task" do
    {job, attempt} = started_job()

    assert_received {:started, %{"cwd" => "~/app", "prompt" => prompt}}
    assert prompt =~ "Add login"
    assert attempt.state == :started
    assert attempt.agent_run_id
    assert job_status(job) == :in_progress
  end

  test "picking a job up moves its task to in progress before the run starts" do
    test = self()
    task = agent_task()

    Req.Test.stub(ClaudeBridge, fn conn ->
      send(test, {:task_at_start, Board.get_task!(task.id)})
      Req.Test.json(conn, %{"id" => "abcd1234", "claudeSessionId" => Ecto.UUID.generate()})
    end)

    Scheduling.create_job!(Map.put(job_attrs(task), :stage, :coding))
    Phoenix.PubSub.subscribe(Weworkai.PubSub, "tasks")

    Scheduler.dispatch_due()

    assert_received {:task_at_start, %{status: :in_progress, stage: :coding}}
    assert_received {:task_updated, %{status: :in_progress}}
  end

  test "a start the bridge rejects fails the job at once with a readable error" do
    stub_bridge(:rejected)
    job = Scheduling.create_job!(job_attrs(agent_task()))

    Scheduler.dispatch_due()

    assert [%{state: :failed, error: "~/app is not a folder on this computer"}] = attempts(job)
    assert job_status(job) == :failed

    task = Board.get_task!(job.task_id)
    assert task.status == :await_human_supervision
    reason = "The coder can't start: ~/app is not a folder on this computer"
    assert [%{kind: :system, body: ^reason}] = Board.list_messages!(task.id)

    assert [%{kind: :agent_failed, body: ^reason}, %{kind: :started}] =
             Notifications.recent_notifications!()
  end

  test "an agent without a model fails its job at once, saying what to fix" do
    stub_bridge(:ok)
    job = Scheduling.create_job!(job_attrs(agent_task()))

    job.agent_id
    |> Agents.get_agent!()
    |> Ash.Changeset.for_update(:assign_role, %{role: :coder})
    |> Ash.Changeset.force_change_attributes(%{model: nil})
    |> Ash.update!()

    Scheduler.dispatch_due()

    assert [%{state: :failed, error: error}] = attempts(job)
    assert error == "Ada has no model yet. Configure it on the Employees page."
    assert job_status(job) == :failed
    refute_received {:started, _body}

    assert %{status: :await_human_supervision} = Board.get_task!(job.task_id)

    assert [%{kind: :agent_failed, body: "The coder can't start: " <> ^error}, %{kind: :started}] =
             Notifications.recent_notifications!()
  end

  test "a failed start retries with backoff, then fails the job" do
    stub_bridge(:unavailable)
    job = Scheduling.create_job!(job_attrs(agent_task()))

    Scheduler.dispatch_due()

    assert [%{state: :failed, error: error}, %{state: :pending, attempt: 2} = retry] =
             attempts(job)

    assert error == "Claude bridge failed: bridge down."
    assert Board.get_task!(job.task_id).status == :in_progress
    assert DateTime.after?(retry.run_at, DateTime.utc_now())

    make_due(retry)
    Scheduler.dispatch_due()
    [_, _, third] = attempts(job)
    make_due(third)
    Scheduler.dispatch_due()

    assert Enum.map(attempts(job), & &1.state) == [:failed, :failed, :failed]
    assert job_status(job) == :failed
  end

  test "an attempt that raises fails on its own; the rest of the tick goes on" do
    stub_bridge(:ok)
    task = agent_task()
    broken = Scheduling.create_job!(job_attrs(task))
    healthy = Scheduling.create_job!(job_attrs(task))

    # A status the job can't be started from, so dispatching it raises.
    Repo.update_all(from(j in "jobs", where: j.id == type(^broken.id, Ecto.UUID)),
      set: [status: "done"]
    )

    log = capture_log(fn -> Scheduler.dispatch_due() end)

    assert log =~ "Scheduler: attempt"
    assert [%{state: :failed, error: error}, %{state: :pending, attempt: 2}] = attempts(broken)
    assert error =~ "status"
    refute error =~ "Bread Crumbs"
    assert job_status(healthy) == :in_progress
  end

  test "the scheduler keeps ticking after a tick lands while its code is reloaded" do
    stub_bridge(:ok)
    task = agent_task()
    pid = start_supervised!(Scheduler)
    Req.Test.allow(ClaudeBridge, self(), pid)
    beam = List.to_string(:code.which(Scheduler))

    on_exit(fn ->
      if File.exists?(beam <> ".reloading"), do: File.rename!(beam <> ".reloading", beam)
      Code.ensure_loaded!(Scheduler)
    end)

    # A dev code reload purges the module and removes its beam until the new one is
    # written; gen_server silently drops a message whose callback module can't be loaded.
    # Purging kills a process inside the module, so the scheduler (busy with a tick, or
    # with the poller's first update) is suspended between messages first.
    send(pid, :tick)
    :ok = :sys.suspend(pid)
    File.rename!(beam, beam <> ".reloading")
    :code.delete(Scheduler)
    :code.purge(Scheduler)
    :erlang.trace(pid, true, [:receive])
    :ok = :sys.resume(pid)
    assert_receive {:trace, ^pid, :receive, :tick}, 2_000
    :erlang.trace(pid, false, [:receive])
    _ = :sys.get_state(pid)
    File.rename!(beam <> ".reloading", beam)
    Code.ensure_loaded!(Scheduler)

    Phoenix.PubSub.subscribe(Weworkai.PubSub, "tasks")
    Scheduling.create_job!(job_attrs(task))
    assert_receive {:task_updated, %{status: :in_progress}}, 3_000
  end

  test "a job canceled while its run starts stops that run and is not retried" do
    test = self()
    job = Scheduling.create_job!(job_attrs(agent_task()))

    # A human moves the task out while the bridge is starting the run.
    Req.Test.stub(ClaudeBridge, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/sessions"} ->
          Scheduling.cancel_job!(Scheduling.get_job!(job.id))

          Req.Test.json(conn, %{
            "id" => "abcd1234",
            "claudeSessionId" => "0b5e7f0e-3c1a-4d2b-9f6e-2a7c8d9e1f00"
          })

        {"POST", "/sessions/abcd1234/stop"} ->
          send(test, :stopped)
          Req.Test.json(conn, %{"id" => "abcd1234"})
      end
    end)

    capture_log(fn -> Scheduler.dispatch_due() end)

    assert_received :stopped
    assert job_status(job) == :canceled
    assert [%{state: :canceled}] = attempts(job)
    assert Agents.active_runs!() == []
  end

  test "a finished run completes the job and queues the next one" do
    {job, attempt} = started_job()

    next =
      Scheduling.create_job!(job_attrs(Board.get_task!(job.task_id), %{previous_job_id: job.id}))

    Scheduler.sync_runs(%{attempt.agent_run_id => :working})
    assert job_status(job) == :in_progress

    Scheduler.sync_runs(%{attempt.agent_run_id => :done})
    assert job_status(job) == :done
    assert [%{state: :completed}] = attempts(job)
    assert [%{state: :pending}] = attempts(next)
  end

  test "a failed run fails the job without retrying or queueing the next one" do
    {job, attempt} = started_job()

    next =
      Scheduling.create_job!(job_attrs(Board.get_task!(job.task_id), %{previous_job_id: job.id}))

    Scheduler.sync_runs(%{attempt.agent_run_id => :failed})
    assert job_status(job) == :failed
    assert [%{state: :failed, error: "The agent run failed; see its log."}] = attempts(job)
    assert attempts(next) == []
  end

  test "a run the bridge forgot fails the job" do
    {job, attempt} = started_job()

    Scheduler.sync_runs(%{attempt.agent_run_id => :ended})
    assert job_status(job) == :failed
  end

  test "a run whose connector was removed fails its job instead of running forever" do
    {job, attempt} = started_job()

    Connectors.remove_connector!(Connectors.get_connector!(connector_id(job)))
    SessionPoller.watch_runs()
    assert_receive {:runs, _runs, statuses}

    Scheduler.sync_runs(statuses)
    assert job_status(job) == :failed
    assert [%{state: :failed}] = attempts(job)
    assert Board.get_task!(job.task_id).status == :await_human_supervision
    assert Agents.get_run!(attempt.agent_run_id).stopped_at
  end

  test "a run stopped on the bridge cancels the job" do
    {job, attempt} = started_job()

    Scheduler.sync_runs(%{attempt.agent_run_id => :stopped})
    assert job_status(job) == :canceled
    assert Agents.get_run!(attempt.agent_run_id).stopped_at
  end

  test "a run stopped from the UI cancels the job; one missing from the snapshot does not" do
    {job, attempt} = started_job()

    Scheduler.sync_runs(%{})
    assert job_status(job) == :in_progress

    Agents.stop_run!(Agents.get_run!(attempt.agent_run_id))
    Scheduler.sync_runs(%{})
    assert job_status(job) == :canceled
    assert [%{state: :canceled}] = attempts(job)
  end

  describe "timeouts" do
    defp minutes_later(minutes), do: DateTime.add(DateTime.utc_now(), minutes * 60)

    test "a run within its limits, or whose silence is unknown, keeps running" do
      {job, attempt} = started_job()
      statuses = %{attempt.agent_run_id => :working}

      Scheduler.sync_runs(
        statuses,
        %{attempt.agent_run_id => DateTime.utc_now()},
        minutes_later(9)
      )

      Scheduler.sync_runs(statuses, %{}, minutes_later(60))

      assert job_status(job) == :in_progress
      assert [%{state: :started}] = attempts(job)
    end

    test "a silent run is stopped and retried, logged on the task and announced" do
      {job, attempt} = started_job()
      started_at = Scheduling.get_job!(job.id).started_at

      Scheduler.sync_runs(
        %{attempt.agent_run_id => :working},
        %{attempt.agent_run_id => DateTime.utc_now()},
        minutes_later(15)
      )

      assert [%{state: :failed, error: error}, %{state: :pending, attempt: 2} = retry] =
               attempts(job)

      assert error == "The agent wrote nothing for 15 minutes, so its run was stopped."
      assert job_status(job) == :on_start
      assert Agents.get_run!(attempt.agent_run_id).stopped_at
      assert Board.get_task!(job.task_id).status == :in_progress

      assert [%{kind: :stalled, label: "The coder stalled: silent for 15m"}] =
               Board.list_events!(job.task_id)

      assert [%{kind: :agent_stalled, body: body} | _] = Notifications.recent_notifications!()
      assert body == error <> " Retrying (attempt 2)."

      make_due(retry)
      Scheduler.dispatch_due()
      assert %{status: :in_progress, started_at: ^started_at} = Scheduling.get_job!(job.id)
    end

    test "a block's own limits apply, and a human takes over once no retry is left" do
      stub_bridge(:ok)

      job =
        Scheduling.create_job!(job_attrs(agent_task(), %{turn_timeout_minutes: 5}))

      for _attempt <- 1..3 do
        attempt = Enum.find(attempts(job), &(&1.state == :pending))
        make_due(attempt)
        Scheduler.dispatch_due()
        %{agent_run_id: run_id} = Ash.reload!(attempt)
        Scheduler.sync_runs(%{run_id => :working}, %{}, minutes_later(5))
      end

      assert Enum.map(attempts(job), & &1.state) == [:failed, :failed, :failed]
      assert job_status(job) == :failed

      task = Board.get_task!(job.task_id)
      assert task.status == :await_human_supervision
      reason = "The agent ran past its 5 minutes turn timeout, so its run was stopped."
      assert [%{kind: :system, body: ^reason}] = Board.list_messages!(task.id)
      assert [%{kind: :agent_failed, body: ^reason} | _] = Notifications.recent_notifications!()
      assert Enum.map(Board.list_events!(task.id), & &1.kind) == List.duplicate(:timed_out, 3)
    end
  end

  test "the poller reports when each run's session last wrote anything" do
    {_job, attempt} = started_job()
    last_event = "2026-10-28T10:00:00.000000Z"

    Req.Test.stub(ClaudeBridge, fn conn ->
      Req.Test.json(conn, %{
        "sessions" => [
          %{"id" => "abcd1234", "status" => "running", "lastEventAt" => last_event}
        ]
      })
    end)

    Req.Test.allow(ClaudeBridge, self(), Process.whereis(SessionPoller))
    SessionPoller.watch_runs()
    assert_receive {:runs, [run], %{} = statuses}
    assert statuses[attempt.agent_run_id] == :working
    assert {:ok, at, 0} = DateTime.from_iso8601(last_event)
    assert Ash.Resource.get_metadata(run, :last_event_at) == at
  end

  test "hold cancels the queued attempt and resume queues a new one" do
    job = Scheduling.create_job!(job_attrs(agent_task()))

    job = Scheduling.hold_job!(job)
    assert [%{state: :canceled}] = attempts(job)

    Scheduling.resume_job!(job)

    assert [%{state: :canceled}, %{state: :pending}] =
             attempts(job) |> Enum.sort_by(& &1.inserted_at)

    assert job_status(job) == :before_start
  end

  test "an illegal transition is rejected" do
    {job, _attempt} = started_job()

    assert {:error, %Ash.Error.Invalid{}} = Scheduling.hold_job(Scheduling.get_job!(job.id))
  end
end
