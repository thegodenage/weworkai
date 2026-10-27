defmodule Weworkai.Connectors do
  use Ash.Domain, otp_app: :weworkai, extensions: [AshPhoenix]

  require Ash.Query

  alias Weworkai.Connectors.Connector
  alias Weworkai.Connectors.Connector.Provider

  @doc "Models and effort levels the connector's provider offers right now."
  def model_options(connector), do: adapter(connector).model_options()

  def start_session(connector, spec), do: adapter(connector).start_session(spec)

  def list_sessions(connector), do: adapter(connector).list_sessions()

  def session(connector, id), do: adapter(connector).session(id)

  def stop_session(connector, id), do: adapter(connector).stop_session(id)

  def create_worktree(connector, repo, name), do: adapter(connector).create_worktree(repo, name)

  def worktree_diff(connector, path), do: adapter(connector).worktree_diff(path)

  defp adapter(connector), do: Provider.adapter(connector.provider)

  @doc "Number of connectors listed before `connector` under `filters`, in list order."
  def position(connector, filters) do
    Connector
    |> Ash.Query.for_read(:list, filters)
    |> Ash.Query.filter(
      name < ^connector.name or (name == ^connector.name and id < ^connector.id)
    )
    |> Ash.count!()
  end

  resources do
    resource Weworkai.Connectors.Connector do
      define :list_connectors, action: :list
      define :connector_options, action: :read, default_options: [query: [sort: [name: :asc]]]
      define :get_connector, action: :read, get_by: [:id]
      define :create_connector, action: :create
      define :update_connector, action: :update
      define :authenticate_connector, action: :authenticate
      define :remove_connector, action: :destroy
    end

    resource Weworkai.Connectors.Auth
  end
end
