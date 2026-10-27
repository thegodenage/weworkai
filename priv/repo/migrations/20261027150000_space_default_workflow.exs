defmodule Weworkai.Repo.Migrations.SpaceDefaultWorkflow do
  @moduledoc """
  The seeded default workflow's blocks sat 260px apart, leaving 40px between blocks the
  editor draws 220px wide: too little for an arrow and its label. Spreads the untouched
  seed (and copies of it) to 320px apart.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE workflow_nodes SET x = x / 260 * 320
    WHERE y = 0 AND x % 260 = 0 AND x BETWEEN 260 AND 1560 AND group_id IS NULL
      AND workflow_id IN (
        SELECT workflow_id FROM workflow_nodes
        GROUP BY workflow_id
        HAVING count(*) = 7 AND bool_and(y = 0 AND x % 260 = 0)
      )
    """)
  end

  def down, do: :ok
end
