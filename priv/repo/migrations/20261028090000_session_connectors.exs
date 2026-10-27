defmodule Weworkai.Repo.Migrations.SessionConnectors do
  @moduledoc """
  The connector each of a task's conversations (planner, coder) ran on: a conversation can
  only be resumed on its own bridge, so an agent on another connector starts its own.
  """

  use Ecto.Migration

  def up do
    alter table(:tasks) do
      add :plan_session_connector_id, :uuid
      add :code_session_connector_id, :uuid
    end
  end

  def down do
    alter table(:tasks) do
      remove :plan_session_connector_id
      remove :code_session_connector_id
    end
  end
end
