defmodule Weworkai.Repo.Migrations.CronsTagsAndGroups do
  @moduledoc """
  Crons (docs/recurring.md), task tags and task groups: a cron's tasks are tagged CRON,
  remember their cron and slot, and runs close together share a group.

  Generated with `mix ash_postgres.generate_migrations`.
  """

  use Ecto.Migration

  def up do
    create table(:crons, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :mode, :text, null: false, default: "weekly"
      add :days, {:array, :bigint}, null: false, default: [1, 2, 3, 4, 5]
      add :at, :time, null: false, default: fragment("'09:00:00'")
      add :expression, :text
      add :timezone, :text, null: false, default: "Etc/UTC"
      add :description, :text
      add :repository, :text, null: false, default: "~/Projects"
      add :next_run_at, :utc_datetime_usec
      add :last_run_at, :utc_datetime_usec
      add :last_skipped_at, :utc_datetime_usec
      add :last_error, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :workflow_id,
          references(:workflows,
            column: :id,
            name: "crons_workflow_id_fkey",
            type: :uuid,
            prefix: "public"
          ),
          null: false
    end

    create index(:crons, [:next_run_at], where: "enabled")

    create table(:task_groups, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :cron_id,
          references(:crons,
            column: :id,
            name: "task_groups_cron_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :nilify_all
          )
    end

    alter table(:tasks) do
      add :tags, {:array, :text}, null: false, default: []
      add :cron_run_at, :utc_datetime_usec

      add :cron_id,
          references(:crons,
            column: :id,
            name: "tasks_cron_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :nilify_all
          )

      add :group_id,
          references(:task_groups,
            column: :id,
            name: "tasks_group_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :nilify_all
          )
    end

    create index(:tasks, [:cron_id])

    create index(:tasks, [:group_id])
  end

  def down do
    drop_if_exists index(:tasks, [:group_id])

    drop_if_exists index(:tasks, [:cron_id])

    drop constraint(:tasks, "tasks_group_id_fkey")

    drop constraint(:tasks, "tasks_cron_id_fkey")

    alter table(:tasks) do
      remove :group_id
      remove :cron_id
      remove :cron_run_at
      remove :tags
    end

    drop constraint(:task_groups, "task_groups_cron_id_fkey")

    drop table(:task_groups)

    drop_if_exists index(:crons, [:next_run_at])

    drop constraint(:crons, "crons_workflow_id_fkey")

    drop table(:crons)
  end
end
