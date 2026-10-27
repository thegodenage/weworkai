defmodule Weworkai.Organization.Employee.Changes.ProvisionAgent do
  @moduledoc """
  Keeps an agent employee's Agent in step with the form: creates it on first save, applies
  the chosen role and links the chosen connector. Agents carry their role on the Agent, so
  the employee's free-text role is cleared.
  """
  use Ash.Resource.Change

  alias Weworkai.Agents

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      role = Ash.Changeset.get_argument(changeset, :agent_role)
      agent = agent_in_role(changeset.data.agent_id, role)
      Agents.link_connector!(agent.id, Ash.Changeset.get_argument(changeset, :connector_id))

      changeset
      |> Ash.Changeset.force_change_attribute(:agent_id, agent.id)
      |> Ash.Changeset.force_change_attribute(:role, nil)
    end)
  end

  defp agent_in_role(nil, role), do: Agents.create_agent!(%{role: role})

  defp agent_in_role(agent_id, role) do
    agent_id |> Agents.get_agent!() |> Agents.assign_agent_role!(%{role: role})
  end
end
