defmodule Weworkai.Board.Task.Changes.DefaultRepository do
  @moduledoc """
  A repository left blank is the bridge's default allowed folder, so every task has a
  folder its agents can start in.
  """
  use Ash.Resource.Change

  alias Weworkai.Board.Task

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :repository) do
      nil ->
        Ash.Changeset.force_change_attribute(changeset, :repository, Task.default_repository())

      _repository ->
        changeset
    end
  end
end
