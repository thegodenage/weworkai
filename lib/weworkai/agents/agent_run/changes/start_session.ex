defmodule Weworkai.Agents.AgentRun.Changes.StartSession do
  @moduledoc """
  Starts the agent's headless run on its connector with the agent's model, effort, role
  profile and prompt. The run is only saved when the provider started it. Failures are
  typed so the scheduler can tell a start that can never work (`NotRunnable`, `Rejected`)
  from one worth retrying (`Unavailable`).
  """
  use Ash.Resource.Change

  alias Weworkai.{Agents, Connectors}
  alias Weworkai.Agents.Agent.Role
  alias Weworkai.Agents.Errors.{NotRunnable, Rejected, Unavailable}

  @impl true
  def change(changeset, _opts, _context) do
    # Starting the session is a call to the user's computer; keep it outside the transaction.
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      agent_id = Ash.Changeset.get_argument(changeset, :agent_id)
      agent = Agents.get_agent!(agent_id, load: [:employee, connector_link: :connector])

      case Agents.missing_setup(agent) do
        nil ->
          start(changeset, agent)

        missing ->
          error = NotRunnable.exception(name: agent.employee.name, missing: missing)
          Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  defp start(changeset, agent) do
    name = "cph-" <> Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false)

    spec = %{
      name: name,
      folder: Ash.Changeset.get_attribute(changeset, :folder),
      model: agent.model,
      effort: agent.effort,
      profile: Role.profile(agent.role),
      system_prompt: agent.prompt,
      task: Ash.Changeset.get_attribute(changeset, :task),
      json_schema: Ash.Changeset.get_argument(changeset, :json_schema),
      resume: Ash.Changeset.get_argument(changeset, :resume),
      fork: Ash.Changeset.get_argument(changeset, :fork),
      attachments: Ash.Changeset.get_argument(changeset, :attachments)
    }

    case Connectors.start_session(agent.connector_link.connector, spec) do
      {:ok, started} ->
        Ash.Changeset.force_change_attributes(changeset,
          session_id: started.id,
          session_name: name,
          claude_session_id: started.claude_session_id
        )

      {:error, {:rejected, reason}} ->
        Ash.Changeset.add_error(changeset, Rejected.exception(reason: reason))

      {:error, reason} ->
        Ash.Changeset.add_error(changeset, Unavailable.exception(reason: reason))
    end
  end
end
