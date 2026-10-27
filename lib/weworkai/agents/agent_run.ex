defmodule Weworkai.Agents.AgentRun do
  @moduledoc """
  One piece of work an agent was started on: a headless run on the agent's connector,
  working on `task` in `folder`. Live status, log and result come from the provider.
  `claude_session_id` is the provider's conversation, which a later run can `resume`.
  """
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Agents,
    data_layer: AshPostgres.DataLayer

  alias Weworkai.Agents.AgentRun.Changes

  postgres do
    table "agent_runs"
    repo Weworkai.Repo

    references do
      reference :agent, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    # The command palette's candidates: `pattern` is a `Weworkai.Fuzzy.pattern/1`.
    read :search do
      argument :pattern, :string, allow_nil?: false
      filter expr(ilike(task, ^arg(:pattern)))
      prepare build(sort: [inserted_at: :desc], limit: 20, load: [agent: :employee])
    end

    read :active do
      filter expr(is_nil(stopped_at))

      prepare build(
                sort: [inserted_at: :desc],
                load: [agent: [:employee, connector_link: :connector]]
              )
    end

    create :start do
      accept [:folder, :task]
      argument :agent_id, :uuid, allow_nil?: false
      # The run ends with structured output matching this JSON schema.
      argument :json_schema, :map
      # Continues this earlier conversation with `task` as the next prompt.
      argument :resume, :string, constraints: [match: ~r/^[0-9a-f-]{36}$/]
      # Continues a copy of `resume` instead, leaving that conversation as it was.
      argument :fork, :boolean, allow_nil?: false, default: false

      # Files the run finds in its folder (`Weworkai.Workflows.Engine.attachments/1`); never stored.
      argument :attachments, :map

      change manage_relationship(:agent_id, :agent, type: :append)
      change Changes.StartSession
    end

    # Canceling a job stops its run inside the job's transaction; the stop call is short.
    update :stop do
      require_atomic? false
      change set_context(%{warn_on_transaction_hooks?: false})
      change Changes.StopSession
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :session_id, :string, allow_nil?: false, public?: true
    attribute :session_name, :string, allow_nil?: false, public?: true
    attribute :claude_session_id, :string, allow_nil?: false, public?: true

    attribute :folder, :string do
      allow_nil? false
      public? true
      constraints max_length: 1000
    end

    attribute :task, :string do
      allow_nil? false
      public? true
      constraints max_length: 400_000, trim?: false
    end

    attribute :stopped_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :agent, Weworkai.Agents.Agent, allow_nil?: false
    # Recorded once the run ended and its result was consumed.
    has_one :usage, Weworkai.Agents.RunUsage
  end
end
