defmodule Weworkai.Connectors.Connector do
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Connectors,
    data_layer: AshPostgres.DataLayer

  alias Weworkai.Connectors.Connector.{Provider, Status}

  postgres do
    table "connectors"
    repo Weworkai.Repo
  end

  actions do
    defaults [:read]

    read :list do
      argument :search, :string
      argument :provider, Provider
      argument :status, Status

      filter expr(
               (is_nil(^arg(:search)) or
                  contains(string_downcase(name), string_downcase(^arg(:search)))) and
                 (is_nil(^arg(:provider)) or provider == ^arg(:provider)) and
                 (is_nil(^arg(:status)) or status == ^arg(:status))
             )

      prepare build(sort: [name: :asc, id: :asc], load: [:auth])
      pagination offset?: true, default_limit: 20, countable: true
    end

    create :create do
      accept [:name, :provider]
    end

    update :update do
      accept [:name]
    end

    update :authenticate do
      require_atomic? false
      change Weworkai.Connectors.Connector.Changes.Authenticate
    end

    destroy :destroy do
      primary? true
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 100
    end

    attribute :provider, Provider do
      allow_nil? false
      public? true
    end

    attribute :status, Status do
      allow_nil? false
      public? true
      default :disconnected
    end

    attribute :status_message, :string, public?: true

    timestamps()
  end

  relationships do
    has_one :auth, Weworkai.Connectors.Auth
  end
end
