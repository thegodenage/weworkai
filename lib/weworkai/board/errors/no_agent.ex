defmodule Weworkai.Board.Errors.NoAgent do
  @moduledoc """
  No agent has the role a step needs, so nobody could run it. `block`: the workflow block
  that needs it, when there is one. `connector`: the connected connector a default agent
  (`Organization.DefaultAgent`) could not be made on, when there is one.
  """
  use Splode.Error, fields: [:role, :block, :connector], class: :invalid

  alias Weworkai.Agents.Agent.Role

  def message(%{block: nil} = error), do: missing(error)
  def message(%{block: block} = error), do: "#{block} can't run: #{missing(error)}"

  defp missing(%{role: role, connector: nil}),
    do: "No #{String.downcase(Role.label(role))} agent yet. Add one on the Employees page."

  defp missing(%{role: role, connector: connector}),
    do:
      "No #{String.downcase(Role.label(role))} agent yet, and #{connector.name} lists no " <>
        "models to make a default one. Check it on the Connectors page."
end
