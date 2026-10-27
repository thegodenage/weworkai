defmodule Weworkai.Repo.Migrations.AuditTimeline do
  @moduledoc """
  What the audit timeline reads: the block each job ran for and when its run started and
  ended, and a log of the human steps on a task. Jobs from before keep no block; their
  times are filled in from their attempts.
  """

  use Ecto.Migration

  def up do
    alter table(:jobs) do
      add :node_id, :uuid
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
    end

    create table(:task_events, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :kind, :text, null: false
      add :label, :text, null: false
      add :node_id, :uuid

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :task_id,
          references(:tasks,
            column: :id,
            name: "task_events_task_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false
    end

    create index(:task_events, [:task_id])

    # A job's run started with the first agent run one of its attempts started.
    execute """
    UPDATE jobs SET started_at = runs.started_at
    FROM (
      SELECT sj.job_id, min(ar.inserted_at) AS started_at
      FROM scheduled_jobs sj JOIN agent_runs ar ON ar.id = sj.agent_run_id
      GROUP BY sj.job_id
    ) runs
    WHERE runs.job_id = jobs.id
    """

    # An ended job last changed when it ended.
    execute """
    UPDATE jobs SET finished_at = updated_at WHERE status IN ('done', 'failed', 'canceled')
    """
  end

  def down do
    drop constraint(:task_events, "task_events_task_id_fkey")

    drop table(:task_events)

    alter table(:jobs) do
      remove :finished_at
      remove :started_at
      remove :node_id
    end
  end
end
