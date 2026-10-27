defmodule Weworkai.Agents.Errors.NotRunnable do
  @moduledoc """
  The agent lacks a model or a connector, so any run it is given would fail to start.
  `block`: the workflow block it was to run, when there is one.
  """
  use Splode.Error, fields: [:name, :missing, :block], class: :invalid

  def message(%{block: nil} = error), do: lacks(error)
  def message(%{block: block} = error), do: "#{block} can't run: #{lacks(error)}"

  defp lacks(%{name: name, missing: :model}),
    do: "#{name} has no model yet. Configure it on the Employees page."

  defp lacks(%{name: name, missing: :connector}),
    do: "#{name} has no connector yet. Link one on the Employees page."
end

defimpl AshPhoenix.FormData.Error, for: Weworkai.Agents.Errors.NotRunnable do
  def to_form_error(error), do: {:agent_id, Exception.message(error), []}
end
