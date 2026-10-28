defmodule Weworkai.Board.Errors.NoWorktree do
  @moduledoc """
  The task has no worktree: no coder worked on it, so there is no code to review, merge or continue.
  """
  use Splode.Error, fields: [:target], class: :invalid

  def message(%{target: :review}), do: "Nothing to review yet: no code changes"
  def message(%{target: :merge}), do: "Nothing to merge yet: no code changes"
  def message(%{target: :coding}), do: "Nothing to continue coding yet: approve the plan first"
end
