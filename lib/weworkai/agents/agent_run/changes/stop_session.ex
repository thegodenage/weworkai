defmodule Weworkai.Agents.AgentRun.Changes.StopSession do
  @moduledoc """
  Stops the run's session on its connector and marks the run stopped. A session the
  provider no longer knows (or a connector that was removed) has already ended.
  """
  use Ash.Resource.Change

  alias Weworkai.Connectors

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      run = Ash.load!(changeset.data, agent: [connector_link: :connector])

      case stop(run) do
        :ok -> Ash.Changeset.force_change_attribute(changeset, :stopped_at, DateTime.utc_now())
        {:error, message} -> Ash.Changeset.add_error(changeset, message: message)
      end
    end)
  end

  defp stop(%{agent: %{connector_link: nil}}), do: :ok

  defp stop(%{agent: %{connector_link: %{connector: connector}}, session_id: session_id}) do
    case Connectors.stop_session(connector, session_id) do
      {:error, :not_found} -> :ok
      result -> result
    end
  end
end
