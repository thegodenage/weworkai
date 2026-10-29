defmodule Weworkai.Board.Errors.NoAgent do
  @moduledoc """
  No agent has the role a step needs, so nobody could run it. `block`: the workflow block
  that needs it, when there is one. `default_error`: why its default agent
  (`Organization.DefaultAgent`) could not be made on the connected connector, when it
  could not.
  """
  use Splode.Error, fields: [:role, :block, :default_error], class: :invalid

  alias Weworkai.Agents.Agent.Role

  def message(%{block: nil} = error), do: missing(error)
  def message(%{block: block} = error), do: "#{block} can't run: #{missing(error)}"

  defp missing(%{role: role, default_error: nil}),
    do: "No #{String.downcase(Role.label(role))} agent yet. Add one on the Employees page."

  defp missing(%{role: role, default_error: reason}),
    do: "No #{String.downcase(Role.label(role))} agent yet, and #{reason}"
end
