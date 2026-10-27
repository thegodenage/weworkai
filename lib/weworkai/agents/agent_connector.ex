defmodule Weworkai.Agents.AgentConnector do
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Agents,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "agent_connectors"
    repo Weworkai.Repo

    references do
      reference :agent, on_delete: :delete
      # Removing a connector unlinks its agents; the employee list then flags them.
      reference :connector, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :link do
      primary? true
      accept [:agent_id, :connector_id]
      upsert? true
      upsert_identity :one_per_agent
      upsert_fields [:connector_id, :updated_at]
    end
  end

  attributes do
    uuid_primary_key :id
    timestamps()
  end

  relationships do
    belongs_to :agent, Weworkai.Agents.Agent, allow_nil?: false, attribute_writable?: true

    belongs_to :connector, Weworkai.Connectors.Connector,
      allow_nil?: false,
      attribute_writable?: true
  end

  identities do
    # ponytail: one connector per agent; drop this identity to allow several.
    identity :one_per_agent, [:agent_id]
  end
end
