defmodule Weworkai.Agents.Errors.Unavailable do
  @moduledoc "The provider could not be reached or failed; a later start may work."
  use Splode.Error, fields: [:reason], class: :unknown

  def message(%{reason: reason}), do: reason
end

defimpl AshPhoenix.FormData.Error, for: Weworkai.Agents.Errors.Unavailable do
  def to_form_error(error), do: {:folder, error.reason, []}
end
