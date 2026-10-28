defmodule Weworkai.Organization.DefaultAgent do
  @moduledoc """
  The agent a role block ("any planner") runs when no agent has its role yet, so a fresh
  install runs its workflows with only a connector set up: made on first need, named after
  the role, on the first connected connector (`Connectors.first_connected/0`) with the
  first model it offers and the role's default prompt. From then on it is an ordinary agent
  employee, configurable on the Employees page; a role that has any agent, set up or not,
  never gets one.
  """
  alias Weworkai.{Agents, Connectors, Organization}
  alias Weworkai.Agents.Agent.Role

  @doc "Whether a role block in `role` would get a default agent now."
  def available?(role), do: is_nil(in_role(role)) and not is_nil(Connectors.first_connected())

  @doc """
  The role's first agent, made first when it has none; loaded with its employee and
  connector, as `Workflows.Engine` picks agents. Nil when none could be made: no connector
  is connected, or it offers no model. Two tasks entering a role block at once share one.
  """
  def provision(role) do
    :global.trans({{__MODULE__, role}, self()}, fn ->
      with nil <- in_role(role), do: create(role, Connectors.first_connected())
    end)
  end

  defp in_role(role) do
    Agents.list_agents!(
      query: [filter: [role: role], sort: [id: :asc], limit: 1],
      load: [:employee, connector_link: :connector]
    )
    |> List.first()
  end

  defp create(_role, nil), do: nil

  defp create(role, connector) do
    case Connectors.model_options(connector) do
      {:ok, %{models: [%{id: model} | _]}} ->
        employee =
          Organization.create_employee!(%{
            kind: :agent,
            name: Role.label(role),
            agent_role: role,
            connector_id: connector.id
          })

        # Should the connector drop the model in between, the agent stays without one and
        # the block's refusal names what it lacks.
        _ = Agents.configure_agent(Agents.get_agent!(employee.agent_id), %{model: model})
        in_role(role)

      _none ->
        nil
    end
  end
end
