defmodule Weworkai.Organization.Employee do
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Organization,
    data_layer: AshPostgres.DataLayer

  alias Weworkai.{Scheduling, Workflows}
  alias Weworkai.Workflows.Engine
  alias Weworkai.Agents.Agent.Role
  alias Weworkai.Organization.Employee.Changes.ProvisionAgent

  postgres do
    table "employees"
    repo Weworkai.Repo

    check_constraints do
      check_constraint :agent_id, "agent_employees_have_agent",
        check: "(kind = 'agent') = (agent_id IS NOT NULL)",
        message: "must be set exactly when the employee is an agent"

      # Agents take their role from the Agent's role list; only humans have free text.
      check_constraint :role, "only_humans_have_text_role",
        check: "(kind = 'human') = (role IS NOT NULL)",
        message: "is for human employees only"
    end
  end

  actions do
    defaults [:read]

    # The command palette's candidates: `pattern` is a `Weworkai.Fuzzy.pattern/1`.
    read :search do
      argument :pattern, :string, allow_nil?: false
      filter expr(ilike(name, ^arg(:pattern)))
      prepare build(sort: [name: :asc, id: :asc], limit: 20)
    end

    read :list do
      prepare build(sort: [name: :asc, id: :asc], load: [agent: [connector_link: :connector]])
      pagination offset?: true, default_limit: 20, countable: true
    end

    create :create do
      accept [:kind, :name, :role]
      argument :connector_id, :uuid
      argument :agent_role, Role

      validate present(:role), where: [attribute_equals(:kind, :human)]
      validate present([:agent_role, :connector_id]), where: [attribute_equals(:kind, :agent)]
      change ProvisionAgent, where: [attribute_equals(:kind, :agent)]
    end

    update :update do
      accept [:name, :role]
      argument :connector_id, :uuid
      argument :agent_role, Role
      require_atomic? false

      validate present(:role), where: [attribute_equals(:kind, :human)]
      validate present([:agent_role, :connector_id]), where: [attribute_equals(:kind, :agent)]
      change ProvisionAgent, where: [attribute_equals(:kind, :agent)]
      # A new role changes which outcomes its blocks' arrows can name.
      change after_action(&Workflows.recount_after/3), where: [attribute_equals(:kind, :agent)]
    end

    # The agent's jobs go with it; their runs are stopped and their tasks handed to a human
    # first, or the runs would work on unwatched and the tasks wait for nobody.
    destroy :destroy do
      primary? true
      require_atomic? false

      change before_action(fn changeset, _context ->
               %{agent_id: agent_id, name: name} = changeset.data
               reason = "#{name} was removed while working on this task."

               agent_id
               |> Scheduling.agent_active_jobs!()
               |> Enum.each(&Engine.agent_removed(&1, reason))

               changeset
             end),
             where: [attribute_equals(:kind, :agent)]

      change cascade_destroy(:agent)
      # Its blocks name nobody now: their workflows have a problem each.
      change after_action(&Workflows.recount_after/3)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, Weworkai.Organization.Employee.Kind do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 100
    end

    # Humans only; an agent's role lives on its Agent.
    attribute :role, :string do
      public? true
      constraints max_length: 100
    end

    timestamps()
  end

  relationships do
    belongs_to :agent, Weworkai.Agents.Agent
  end
end
