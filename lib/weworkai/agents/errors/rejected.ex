defmodule Weworkai.Agents.Errors.Rejected do
  @moduledoc """
  The provider refused the run as asked (a folder that doesn't exist or isn't allowed, a
  model it doesn't offer): starting it again unchanged fails the same way.
  """
  use Splode.Error, fields: [:reason], class: :invalid

  def message(%{reason: reason}), do: reason
end

# The dashboard's run form shows a refused start under the folder, as it always has.
defimpl AshPhoenix.FormData.Error, for: Weworkai.Agents.Errors.Rejected do
  def to_form_error(error), do: {:folder, error.reason, []}
end
