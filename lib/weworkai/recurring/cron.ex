defmodule Weworkai.Recurring.Cron do
  @moduledoc """
  A workflow run on its own (docs/recurring.md). Its slots are given either as weekdays at
  a time of day (`mode: :weekly`) or as a cron expression (`mode: :expression`), on the
  wall clock of `timezone`. At each, a task named after it, with its description and
  repository, is created on its workflow, tagged CRON, and moved to todo
  (`Weworkai.Recurring.Runner`); runs close together share a task group. `next_run_at` is
  the next slot in UTC, recomputed whenever the cron changes or fires; nil while paused.
  """
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Recurring,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub]

  alias Weworkai.Board.Task
  alias Weworkai.Recurring.Cron.{Changes, Validations}

  @fields [
    :name,
    :workflow_id,
    :enabled,
    :mode,
    :days,
    :at,
    :expression,
    :timezone,
    :description,
    :repository
  ]

  postgres do
    table "crons"
    repo Weworkai.Repo
    migration_defaults days: "[1, 2, 3, 4, 5]"

    custom_indexes do
      index [:next_run_at], where: "enabled"
    end
  end

  actions do
    defaults [:read, :destroy]

    read :list do
      prepare build(
                sort: [name: :asc, inserted_at: :asc],
                load: [:workflow, :task_count, :last_task_id, :last_task_title]
              )
    end

    # The scheduler's: enabled crons whose slot has come.
    read :due do
      argument :now, :utc_datetime_usec, allow_nil?: false
      filter expr(enabled and next_run_at <= ^arg(:now))
      prepare build(sort: [next_run_at: :asc])
    end

    create :create do
      primary? true
      accept @fields
      validate Validations.Timezone
      validate Validations.Expression
      change Changes.NextRun
    end

    update :update do
      primary? true
      accept @fields
      require_atomic? false
      validate Validations.Timezone
      validate Validations.Expression
      change Changes.NextRun
    end

    # It fired or skipped a slot: the next one is set before any task is made, so a run
    # that fails or raises is never repeated on the next tick.
    update :claim do
      accept [:last_run_at, :next_run_at, :last_skipped_at]
    end

    update :record_run do
      accept [:last_error]
    end
  end

  # Fires and edits land on the Recurring tab live.
  pub_sub do
    module Phoenix.PubSub
    name Weworkai.PubSub
    transform fn _notification -> :cron_changed end

    publish_all :create, "crons"
    publish_all :update, "crons"
    publish_all :destroy, "crons"
  end

  attributes do
    uuid_primary_key :id

    # Its tasks' title, before the run's date ("Daily GitLab digest · Wed 28 Oct").
    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 180
    end

    attribute :enabled, :boolean, allow_nil?: false, public?: true, default: true

    # How its slots are given: weekdays and a time (`days`, `at`) or `expression`.
    attribute :mode, :atom do
      allow_nil? false
      public? true
      default :weekly
      constraints one_of: [:weekly, :expression]
    end

    # ISO weekdays: 1 = Monday … 7 = Sunday (weekly mode).
    attribute :days, {:array, :integer} do
      allow_nil? false
      public? true
      default [1, 2, 3, 4, 5]
      constraints min_length: 1, items: [min: 1, max: 7]
    end

    # The time of day on the wall clock of `timezone` (weekly mode).
    attribute :at, :time, allow_nil?: false, public?: true, default: ~T[09:00:00]

    # minute hour day-of-month month weekday, on the clock of `timezone` ("0 9 * * 1-5").
    attribute :expression, :string, public?: true, constraints: [max_length: 200]

    attribute :timezone, :string do
      allow_nil? false
      public? true
      default "Etc/UTC"
      constraints max_length: 100
    end

    # What its tasks are to do: their description.
    attribute :description, :string, public?: true

    attribute :repository, :string do
      allow_nil? false
      public? true
      default Task.default_repository()
      constraints max_length: 1000
    end

    attribute :next_run_at, :utc_datetime_usec, public?: true
    attribute :last_run_at, :utc_datetime_usec, public?: true
    # A slot missed by more than the grace window (the app wasn't running): no task for it.
    attribute :last_skipped_at, :utc_datetime_usec, public?: true
    # Why the last run's task didn't start (its workflow has problems, its agent can't run…).
    attribute :last_error, :string, public?: true, constraints: [max_length: 10_000]

    timestamps()
  end

  relationships do
    belongs_to :workflow, Weworkai.Workflows.Workflow, allow_nil?: false, public?: true
    has_many :tasks, Weworkai.Board.Task, destination_attribute: :cron_id
  end

  aggregates do
    count :task_count, :tasks
    first :last_task_id, :tasks, :id, sort: [cron_run_at: :desc]
    first :last_task_title, :tasks, :title, sort: [cron_run_at: :desc]
  end
end
