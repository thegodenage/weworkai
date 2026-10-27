defmodule Weworkai.Workflows.Version do
  @moduledoc """
  A workflow's graph as one save left it (docs/workflows.md, "Versions"), numbered by the
  workflow's `version` then and never changed afterwards. A task runs the version it is
  pinned to, so editing a workflow leaves the tasks already in it on the graph they started.
  `graph` is in the editor's params shape (`Workflows.params/1`), ids as stored.
  """
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Workflows,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "workflow_versions"
    repo Weworkai.Repo

    references do
      reference :workflow, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:workflow_id, :number, :graph, :problem_count]
    end

    read :history do
      argument :workflow_id, :uuid, allow_nil?: false
      filter expr(workflow_id == ^arg(:workflow_id))
      prepare build(sort: [number: :desc])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :number, :integer, allow_nil?: false, public?: true, constraints: [min: 1]
    attribute :graph, :map, allow_nil?: false, public?: true
    # As saved; whether a task can run it is checked against the employees of the day.
    attribute :problem_count, :integer, allow_nil?: false, public?: true, default: 0

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :workflow, Weworkai.Workflows.Workflow, allow_nil?: false, public?: true
  end

  identities do
    identity :number, [:workflow_id, :number]
  end
end
