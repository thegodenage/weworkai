defmodule Weworkai.Board.Task.Validations.Reviewable do
  @moduledoc "Only a task a coder worked on, in its own worktree, has code to review."
  use Ash.Resource.Validation

  alias Weworkai.Board.Errors.NoWorktree

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :worktree_path) do
      nil -> {:error, NoWorktree.exception(target: :review)}
      _worktree -> :ok
    end
  end
end
