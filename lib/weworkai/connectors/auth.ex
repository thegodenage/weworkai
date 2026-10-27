defmodule Weworkai.Connectors.Auth do
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Connectors,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "connector_auths"
    repo Weworkai.Repo

    references do
      # Removing a connector removes its auth metadata, whichever path deletes it.
      reference :connector, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      primary? true
      accept [:method, :metadata, :verified_at]
      upsert? true
      upsert_identity :one_per_connector
      upsert_fields [:method, :metadata, :verified_at, :updated_at]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :method, Weworkai.Connectors.Auth.Method, allow_nil?: false, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true
    attribute :verified_at, :utc_datetime_usec, allow_nil?: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :connector, Weworkai.Connectors.Connector, allow_nil?: false
  end

  identities do
    identity :one_per_connector, [:connector_id]
  end
end
