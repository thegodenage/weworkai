defmodule Weworkai.Scheduling.StartFailure do
  @moduledoc """
  Why an agent run did not start. `:permanent`: starting it again unchanged fails the same
  way (the agent has no model or connector, the bridge refused the folder or the model), so
  the job fails at once. `:transient`: the bridge could not be reached or failed, so the
  start is retried with backoff.
  """
  alias Weworkai.ErrorText

  @enforce_keys [:kind, :reason]
  defstruct [:kind, :reason]

  def from_error(error) do
    %__MODULE__{kind: kind(Ash.Error.to_error_class(error)), reason: ErrorText.readable(error)}
  end

  def transient(reason), do: %__MODULE__{kind: :transient, reason: reason}

  defp kind(%Ash.Error.Invalid{}), do: :permanent
  defp kind(_other), do: :transient
end
