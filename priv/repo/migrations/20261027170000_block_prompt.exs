defmodule Weworkai.Repo.Migrations.BlockPrompt do
  @moduledoc """
  An agent block's own instructions (`workflow_nodes.prompt`), added to its agent's prompt
  in that workflow only.
  """

  use Ecto.Migration

  def up do
    alter table(:workflow_nodes) do
      add :prompt, :text
    end
  end

  def down do
    alter table(:workflow_nodes) do
      remove :prompt
    end
  end
end
