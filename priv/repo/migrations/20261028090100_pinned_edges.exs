defmodule Weworkai.Repo.Migrations.PinnedEdges do
  @moduledoc """
  `workflow_edges.pinned`: the arrow's dots were chosen by hand (an end dragged onto a
  dot), so moving its blocks keeps them; otherwise the editor picks the facing sides.
  Arrows drawn so far keep the dots they have until one of their blocks moves.
  """

  use Ecto.Migration

  def up do
    alter table(:workflow_edges) do
      add :pinned, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:workflow_edges) do
      remove :pinned
    end
  end
end
