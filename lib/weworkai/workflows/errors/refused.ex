defmodule Weworkai.Workflows.Errors.Refused do
  @moduledoc """
  The task's workflow graph has no way to do what was asked: no reviewer block, no
  approval arrow, a block that was removed or names nobody, a decision no longer open.
  """
  use Splode.Error, fields: [:reason], class: :invalid

  def message(%{reason: reason}), do: reason
end
