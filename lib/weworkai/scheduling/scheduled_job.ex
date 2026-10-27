defmodule Weworkai.Scheduling.ScheduledJob do
  @moduledoc """
  One attempt at a job, due at `run_at`; the scheduler's queue. Each transition also moves
  its job in the same transaction. Transitions filter on the state they move from as well
  as validating it: the scheduler holds an attempt loaded before a human may cancel it, and
  the filter makes the database refuse such a stale move. See docs/scheduler.md.
  """
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Scheduling,
    data_layer: AshPostgres.DataLayer

  alias Weworkai.Scheduling
  alias Weworkai.Scheduling.ScheduledJob.Changes

  postgres do
    table "scheduled_jobs"
    repo Weworkai.Repo

    references do
      reference :job, on_delete: :delete
      reference :agent_run, on_delete: :nilify
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:job_id, :attempt, :run_at]
    end

    # A blocked task's attempts wait here until its blockers close (`Board.TaskDependency`);
    # a human's question about it is answered meanwhile.
    read :due do
      filter expr(
               state == :pending and run_at <= now() and
                 (not job.task.blocked or job.stage == :ask)
             )

      prepare build(sort: [run_at: :asc], load: [job: :task])
    end

    # Attempts of a task's jobs that started an agent run, newest first.
    read :runs_for_task do
      argument :task_id, :uuid, allow_nil?: false
      filter expr(job.task_id == ^arg(:task_id) and not is_nil(agent_run_id))

      prepare build(
                sort: [inserted_at: :desc],
                load: [agent_run: :usage, job: [agent: :employee]]
              )
    end

    read :started do
      filter expr(state == :started)
      prepare build(load: [:job, :agent_run])
    end

    update :mark_started do
      require_atomic? false
      argument :agent_run_id, :uuid, allow_nil?: false
      validate attribute_in(:state, [:pending])
      change filter(expr(state == :pending))
      change set_attribute(:state, :started)
      change set_attribute(:agent_run_id, arg(:agent_run_id))
      change after_action(fn _changeset, attempt, _context -> move_job(attempt, :run_job!) end)
    end

    update :mark_completed do
      require_atomic? false
      validate attribute_in(:state, [:started])
      change filter(expr(state == :started))
      change set_attribute(:state, :completed)

      change after_action(fn _changeset, attempt, _context ->
               move_job(attempt, :complete_job!)
             end)
    end

    update :mark_failed do
      require_atomic? false
      argument :error, :string, allow_nil?: false
      validate attribute_in(:state, [:pending])
      change filter(expr(state == :pending))
      change set_attribute(:state, :failed)
      change set_attribute(:error, arg(:error))
      change Changes.RetryOrFail
    end

    # A start that can't work as asked (agent not set up, bridge refused it): no retry.
    update :mark_rejected do
      require_atomic? false
      argument :error, :string, allow_nil?: false
      validate attribute_in(:state, [:pending])
      change filter(expr(state == :pending))
      change set_attribute(:state, :failed)
      change set_attribute(:error, arg(:error))
      change after_action(fn _changeset, attempt, _context -> move_job(attempt, :fail_job!) end)
    end

    # The run started but failed; not retried, since it may have changed files already.
    update :mark_run_failed do
      require_atomic? false
      argument :error, :string, allow_nil?: false
      validate attribute_in(:state, [:started])
      change filter(expr(state == :started))
      change set_attribute(:state, :failed)
      change set_attribute(:error, arg(:error))
      change after_action(fn _changeset, attempt, _context -> move_job(attempt, :fail_job!) end)
    end

    # The run went silent or ran too long and was stopped: retried like a failed start.
    update :mark_timed_out do
      require_atomic? false
      argument :error, :string, allow_nil?: false
      validate attribute_in(:state, [:started])
      change filter(expr(state == :started))
      change set_attribute(:state, :failed)
      change set_attribute(:error, arg(:error))

      change after_action(fn _changeset, attempt, _context ->
               move_job(attempt, :requeue_job!)
             end)

      change Changes.RetryOrFail
    end

    update :mark_canceled do
      validate attribute_in(:state, [:pending, :started])
      change set_attribute(:state, :canceled)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :state, Weworkai.Scheduling.ScheduledJob.State do
      allow_nil? false
      public? true
      default :pending
    end

    attribute :attempt, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    attribute :run_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
    end

    attribute :error, :string, public?: true

    timestamps()
  end

  relationships do
    belongs_to :job, Weworkai.Scheduling.Job, allow_nil?: false, public?: true
    belongs_to :agent_run, Weworkai.Agents.AgentRun, public?: true
  end

  defp move_job(attempt, action) do
    apply(Scheduling, action, [Ash.load!(attempt, :job).job])
    {:ok, attempt}
  end
end
