defmodule Weworkai.Board.Task.Changes.Unchanged do
  @moduledoc """
  Filters the update on the copy's `updated_at`, so a second tab (or a double click)
  acting on a copy that is no longer current is refused instead of acting twice.
  """
  use Ash.Resource.Change

  import Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.filter(changeset, expr(updated_at == ^changeset.data.updated_at))
  end
end
