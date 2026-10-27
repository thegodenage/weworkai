defmodule Weworkai.Agents.RunUsage do
  @moduledoc """
  The cost ledger: what one agent run used, as its connector reported when the run ended
  (tokens by kind, USD, run time, turns). One row per run, kept with the run's agent and
  task, so spend adds up per run, task, agent and period (`Weworkai.Agents.Usage`).
  A run reports its own turns only, so the runs of one resumed conversation never overlap.
  """
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Agents,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "run_usages"
    repo Weworkai.Repo

    references do
      reference :agent_run, on_delete: :delete
      reference :agent, on_delete: :delete
      # Spend stays on the books when its task is deleted.
      reference :task, on_delete: :nilify
    end

    custom_indexes do
      index [:task_id]
      # Spend per agent and period.
      index [:agent_id, :inserted_at]
    end
  end

  actions do
    defaults [:read]

    # A run's result can be applied twice (at-least-once sync); the second write wins.
    create :record do
      accept [
        :agent_run_id,
        :agent_id,
        :task_id,
        :input_tokens,
        :output_tokens,
        :cache_read_tokens,
        :cache_creation_tokens,
        :cost_usd,
        :duration_ms,
        :turns
      ]

      upsert? true
      upsert_identity :unique_run
    end

    read :for_task do
      argument :task_id, :uuid, allow_nil?: false
      filter expr(task_id == ^arg(:task_id))
    end

    read :for_agent_since do
      argument :agent_id, :uuid, allow_nil?: false
      argument :since, :utc_datetime_usec, allow_nil?: false
      filter expr(agent_id == ^arg(:agent_id) and inserted_at >= ^arg(:since))
    end

    read :since do
      argument :since, :utc_datetime_usec, allow_nil?: false
      filter expr(inserted_at >= ^arg(:since))
      prepare build(load: [agent: :employee])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :input_tokens, :integer, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :output_tokens, :integer, allow_nil?: false, public?: true, constraints: [min: 0]

    attribute :cache_read_tokens, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0]

    attribute :cache_creation_tokens, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0]

    attribute :cost_usd, :decimal, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :duration_ms, :integer, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :turns, :integer, allow_nil?: false, public?: true, constraints: [min: 0]

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :agent_run, Weworkai.Agents.AgentRun, allow_nil?: false, public?: true
    belongs_to :agent, Weworkai.Agents.Agent, allow_nil?: false, public?: true
    belongs_to :task, Weworkai.Board.Task, public?: true
  end

  identities do
    identity :unique_run, [:agent_run_id]
  end
end
