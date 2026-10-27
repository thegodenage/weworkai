defmodule Weworkai.Repo.Migrations.RunTimeouts do
  @moduledoc """
  Limits on each agent run: a job stops and retries a run that writes nothing for
  stall_timeout_minutes or runs for turn_timeout_minutes; a block may set its own.
  """

  use Ecto.Migration

  def up do
    alter table(:jobs) do
      add :stall_timeout_minutes, :bigint, null: false, default: 15
      add :turn_timeout_minutes, :bigint, null: false, default: 120
    end

    alter table(:workflow_nodes) do
      add :stall_timeout_minutes, :bigint
      add :turn_timeout_minutes, :bigint
    end
  end

  def down do
    alter table(:workflow_nodes) do
      remove :turn_timeout_minutes
      remove :stall_timeout_minutes
    end

    alter table(:jobs) do
      remove :turn_timeout_minutes
      remove :stall_timeout_minutes
    end
  end
end
