defmodule Weworkai.Organization.DefaultAgent do
  @moduledoc """
  The agent a role block ("any planner") runs when no agent has its role yet, so a fresh
  install runs its workflows with only a connector set up: made on first need, named after
  the role, on the first connected connector (`Connectors.first_connected/0`) with the
  first model it offers and the role's default prompt. From then on it is an ordinary agent
  employee, configurable on the Employees page; a role that has any agent, set up or not,
  never gets one.
  """
  alias Weworkai.{Agents, Connectors, ErrorText, Organization, Repo}
  alias Weworkai.Agents.Agent.Role

  @doc "Whether a role block in `role` would get a default agent now."
  def available?(role), do: is_nil(in_role(role)) and not is_nil(Connectors.first_connected())

  @doc """
  The role's first agent, made first when it has none; loaded with its employee and
  connector, as `Workflows.Engine` picks agents. `:none` when no connector is connected;
  `{:error, reason}` when one is but the agent could not be made on it, `reason` finishing
  "No planner agent yet, and …". Two tasks entering a role block at once share one.
  """
  def provision(role) do
    :global.trans({{__MODULE__, role}, self()}, fn ->
      case in_role(role) do
        nil -> create(role, Connectors.first_connected())
        agent -> {:ok, agent}
      end
    end)
  end

  defp in_role(role) do
    Agents.list_agents!(
      query: [filter: [role: role], sort: [id: :asc], limit: 1],
      load: [:employee, connector_link: :connector]
    )
    |> List.first()
  end

  defp create(_role, nil), do: :none

  defp create(role, connector) do
    with {:ok, model} <- first_model(connector),
         {:ok, _agent} <- insert(role, connector, model) do
      {:ok, in_role(role)}
    else
      {:error, reason} -> {:error, "none could be made on #{connector.name}: #{reason}"}
    end
  end

  defp first_model(connector) do
    case Connectors.model_options(connector) do
      {:ok, %{models: [%{id: model} | _]}} -> {:ok, model}
      {:ok, _none} -> {:error, "it lists no models."}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _reason} -> {:error, "it did not answer."}
    end
  end

  # One write, so the role never ends up with a half-made agent. The model was just listed
  # by the connector, so :configure's check (another request) is skipped.
  defp insert(role, connector, model) do
    Repo.transaction(fn ->
      with {:ok, employee} <-
             Organization.create_employee(%{
               kind: :agent,
               name: name(role),
               agent_role: role,
               connector_id: connector.id
             }),
           {:ok, agent} <- Agents.get_agent(employee.agent_id),
           {:ok, agent} <-
             agent
             |> Ash.Changeset.for_update(:assign_role, %{role: role})
             |> Ash.Changeset.force_change_attribute(:model, model)
             |> Ash.update() do
        agent
      else
        {:error, error} -> Repo.rollback(ErrorText.readable(error))
      end
    end)
  rescue
    # The connector removed meanwhile: linking it fails its foreign key.
    error -> {:error, ErrorText.readable(error)}
  end

  # The role's label, numbered when an employee has it already ("Planner 2").
  defp name(role) do
    label = Role.label(role)
    taken = MapSet.new(Organization.list_all_employees!(), & &1.name)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> label
      n -> "#{label} #{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end
end
