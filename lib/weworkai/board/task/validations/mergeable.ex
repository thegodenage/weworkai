defmodule Weworkai.Board.Task.Validations.Mergeable do
  @moduledoc "The merger can merge the task's branch now (`Engine.mergeable?/1`)."
  use Ash.Resource.Validation

  alias Weworkai.Board.Errors.NoWorktree
  alias Weworkai.Workflows.Engine

  @impl true
  def validate(changeset, _opts, _context) do
    cond do
      is_nil(changeset.data.worktree_branch) -> {:error, NoWorktree.exception(target: :merge)}
      Engine.mergeable?(changeset.data) -> :ok
      true -> {:error, field: :status, message: "The task isn't waiting for a merge now"}
    end
  end
end
