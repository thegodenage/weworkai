defmodule Weworkai.Workflows.Errors.WorktreeRefused do
  @moduledoc "The bridge could not create the coder's worktree in the task's repository."
  use Splode.Error, fields: [:reason], class: :invalid

  def message(%{reason: reason}), do: "The coder's worktree could not be created: #{reason}"
end
