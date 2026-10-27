defmodule Weworkai.Agents.Agent do
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Agents,
    data_layer: AshPostgres.DataLayer

  alias Weworkai.Agents.Agent.Role

  postgres do
    table "agents"
    repo Weworkai.Repo
  end

  actions do
    defaults [:read, :destroy]

    read :runnable do
      filter expr(not is_nil(model) and exists(connector_link, true))
      prepare build(load: [:employee, connector_link: :connector])
    end

    create :create do
      primary? true
      accept [:role]

      change fn changeset, _context ->
        role = Ash.Changeset.get_attribute(changeset, :role)
        Ash.Changeset.force_change_attribute(changeset, :prompt, Role.default_prompt(role))
      end
    end

    update :assign_role do
      accept [:role]
      require_atomic? false

      # Follow the new role's default prompt unless the prompt was edited by hand.
      change fn changeset, _context ->
        data = changeset.data

        if data.prompt == Role.default_prompt(data.role) do
          role = Ash.Changeset.get_attribute(changeset, :role)
          Ash.Changeset.force_change_attribute(changeset, :prompt, Role.default_prompt(role))
        else
          changeset
        end
      end
    end

    update :configure do
      accept [:model, :effort, :prompt, :budget_usd, :budget_period]
      require_atomic? false

      validate present(:model)
      # Calls the connector, so only when saving, not on every form change.
      validate Weworkai.Agents.Agent.Validations.OfferedByConnector, before_action?: true
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, Role do
      allow_nil? false
      public? true
      default :custom
    end

    attribute :model, :string do
      public? true
      constraints max_length: 100
    end

    # nil leaves the provider's default effort.
    attribute :effort, :string do
      public? true
      constraints max_length: 20
    end

    attribute :prompt, :string do
      public? true
      constraints max_length: 20_000, trim?: false
    end

    # USD the agent may spend per `budget_period`; nil leaves it uncapped (`Weworkai.Agents.Budget`).
    attribute :budget_usd, :decimal, public?: true, constraints: [greater_than: 0]

    attribute :budget_period, Weworkai.Agents.Agent.BudgetPeriod do
      allow_nil? false
      public? true
      default :day
    end
  end

  relationships do
    has_one :connector_link, Weworkai.Agents.AgentConnector

    has_one :employee, Weworkai.Organization.Employee do
      destination_attribute :agent_id
    end

    has_many :runs, Weworkai.Agents.AgentRun
  end
end
