defmodule Weworkai.Repo.Migrations.RunUsageLedger do
  @moduledoc """
  The cost ledger (`Weworkai.Agents.RunUsage`): what each agent run used, one row per run.
  """

  use Ecto.Migration

  def up do
    create table(:run_usages, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :input_tokens, :bigint, null: false
      add :output_tokens, :bigint, null: false
      add :cache_read_tokens, :bigint, null: false
      add :cache_creation_tokens, :bigint, null: false
      add :cost_usd, :decimal, null: false
      add :duration_ms, :bigint, null: false
      add :turns, :bigint, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :agent_run_id,
          references(:agent_runs,
            column: :id,
            name: "run_usages_agent_run_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false
    end

    create unique_index(:run_usages, [:agent_run_id], name: "run_usages_unique_run_index")

    alter table(:run_usages) do
      add :agent_id,
          references(:agents,
            column: :id,
            name: "run_usages_agent_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :task_id,
          references(:tasks,
            column: :id,
            name: "run_usages_task_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :nilify_all
          )
    end

    create index(:run_usages, [:task_id])

    create index(:run_usages, [:agent_id, :inserted_at])
  end

  def down do
    drop_if_exists index(:run_usages, [:agent_id, :inserted_at])

    drop_if_exists index(:run_usages, [:task_id])

    drop constraint(:run_usages, "run_usages_task_id_fkey")

    drop constraint(:run_usages, "run_usages_agent_id_fkey")

    drop constraint(:run_usages, "run_usages_agent_run_id_fkey")

    alter table(:run_usages) do
      remove :task_id
      remove :agent_id
    end

    drop_if_exists unique_index(:run_usages, [:agent_run_id], name: "run_usages_unique_run_index")

    drop table(:run_usages)
  end
end
