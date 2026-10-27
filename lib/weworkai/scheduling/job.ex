defmodule Weworkai.Scheduling.Job do
  @moduledoc """
  One agent run on a board task: which agent, in which folder, with which prompt, and
  optionally the JSON schema its result must match and the conversation it continues.
  Jobs chain through `previous_job_id`: a job is only queued once the previous one is done.
  Attempts live in `ScheduledJob`. See docs/scheduler.md.
  """
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Scheduling,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub]

  alias Weworkai.Scheduling.Job.Changes

  postgres do
    table "jobs"
    repo Weworkai.Repo

    references do
      reference :task, on_delete: :delete
      reference :agent, on_delete: :delete
      reference :previous_job, on_delete: :nilify
    end
  end

  actions do
    defaults [:read]

    # The task's workflow jobs the scheduler will still start or is running. Questions are
    # left out: they run beside the workflow and never hold it up.
    read :active do
      argument :task_id, :uuid, allow_nil?: false

      filter expr(
               task_id == ^arg(:task_id) and (is_nil(stage) or stage != :ask) and
                 status in [:before_start, :on_start, :in_progress, :on_hold]
             )
    end

    # The task's questions still waiting for their answer.
    read :active_asks do
      argument :task_id, :uuid, allow_nil?: false

      filter expr(
               task_id == ^arg(:task_id) and stage == :ask and
                 status in [:before_start, :on_start, :in_progress, :on_hold]
             )
    end

    # The task's newest workflow job with its attempts; nil when it never had one.
    read :latest do
      argument :task_id, :uuid, allow_nil?: false
      get? true
      filter expr(task_id == ^arg(:task_id) and (is_nil(stage) or stage != :ask))
      prepare build(sort: [inserted_at: :desc], limit: 1, load: [:scheduled_jobs])
    end

    # Every job of the task, oldest first, with who ran it and its attempts (the audit
    # timeline, Weworkai.Audit.Timeline).
    read :for_task do
      argument :task_id, :uuid, allow_nil?: false
      filter expr(task_id == ^arg(:task_id))
      prepare build(sort: [inserted_at: :asc], load: [:scheduled_jobs, agent: :employee])
    end

    read :active_for_agent do
      argument :agent_id, :uuid, allow_nil?: false

      filter expr(
               agent_id == ^arg(:agent_id) and
                 status in [:before_start, :on_start, :in_progress, :on_hold]
             )
    end

    create :create do
      accept [
        :task_id,
        :agent_id,
        :node_id,
        :previous_job_id,
        :stage,
        :folder,
        :prompt,
        :json_schema,
        :resume,
        :fork,
        :stall_timeout_minutes,
        :turn_timeout_minutes
      ]

      validate present(:resume), where: [attribute_equals(:fork, true)]
      change Changes.ScheduleWhenReady
    end

    # on_start is allowed again so a retry or a dispatch interrupted by a crash can restart.
    update :start do
      validate attribute_in(:status, [:before_start, :on_start])
      change set_attribute(:status, :on_start)
    end

    # started_at stays the first attempt's, so a retried job's bar covers every run it made.
    update :run do
      validate attribute_in(:status, [:on_start])
      change set_attribute(:status, :in_progress)
      change atomic_update(:started_at, expr(started_at || now()))
    end

    # Its run timed out and is retried: back to waiting for the next attempt.
    update :requeue do
      validate attribute_in(:status, [:in_progress])
      change set_attribute(:status, :on_start)
    end

    update :complete do
      require_atomic? false
      validate attribute_in(:status, [:in_progress])
      change set_attribute(:status, :done)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change Changes.ScheduleNext
    end

    # on_start: every start attempt failed; in_progress: the agent run itself failed.
    update :fail do
      validate attribute_in(:status, [:on_start, :in_progress])
      change set_attribute(:status, :failed)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
    end

    update :cancel do
      require_atomic? false
      validate attribute_in(:status, [:before_start, :on_start, :in_progress, :on_hold])
      change set_attribute(:status, :canceled)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change Changes.CancelAttempts
    end

    # A running agent session cannot be paused, so only a job that hasn't started can be held.
    update :hold do
      require_atomic? false
      validate attribute_in(:status, [:before_start])
      change set_attribute(:status, :on_hold)
      change Changes.CancelAttempts
    end

    update :resume do
      require_atomic? false
      validate attribute_in(:status, [:on_hold])
      change set_attribute(:status, :before_start)
      change Changes.ScheduleWhenReady
    end
  end

  # A job starting, finishing or being canceled changes what the task shows (its
  # `activity`), often without the task itself changing, so it is announced as the task's.
  pub_sub do
    module Phoenix.PubSub
    name Weworkai.PubSub

    transform fn notification -> {:task_updated, %{id: notification.data.task_id}} end

    publish_all :create, "tasks"
    publish_all :update, "tasks"
  end

  attributes do
    uuid_primary_key :id

    attribute :status, Weworkai.Scheduling.Job.Status do
      allow_nil? false
      public? true
      default :before_start
    end

    attribute :folder, :string do
      allow_nil? false
      public? true
      constraints max_length: 1000
    end

    # What the run's result is for (a workflow stage, or a question); nil runs the task as-is.
    attribute :stage, Weworkai.Scheduling.Job.Stage, public?: true

    # The bridge's prompt limit.
    attribute :prompt, :string do
      allow_nil? false
      public? true
      constraints max_length: 400_000, trim?: false
    end

    attribute :json_schema, :map, public?: true

    # Claude conversation the run continues.
    attribute :resume, :string, public?: true, constraints: [match: ~r/^[0-9a-f-]{36}$/]

    # Continues a copy of `resume`, so that conversation is left as it was.
    attribute :fork, :boolean, allow_nil?: false, public?: true, default: false

    # The workflow block the job runs for; no foreign key, blocks are replaced when their
    # graph is saved. nil for a question, and for jobs from before it was kept.
    attribute :node_id, :uuid, public?: true

    # A running agent that writes nothing for this long, or runs this long in all, is stopped
    # and retried (`Weworkai.Scheduling.Timeout`).
    attribute :stall_timeout_minutes, :integer do
      allow_nil? false
      public? true
      default 15
      constraints min: 1, max: 1440
    end

    attribute :turn_timeout_minutes, :integer do
      allow_nil? false
      public? true
      default 120
      constraints min: 1, max: 1440
    end

    # When its agent run started, and when the job ended (done, failed or canceled).
    attribute :started_at, :utc_datetime_usec, public?: true
    attribute :finished_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :task, Weworkai.Board.Task, allow_nil?: false, public?: true
    belongs_to :agent, Weworkai.Agents.Agent, allow_nil?: false, public?: true
    belongs_to :previous_job, __MODULE__, public?: true

    has_many :next_jobs, __MODULE__ do
      destination_attribute :previous_job_id
    end

    has_many :scheduled_jobs, Weworkai.Scheduling.ScheduledJob
  end
end
