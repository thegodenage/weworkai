defmodule Weworkai.Workflows.Workflow do
  @moduledoc """
  A named graph of blocks and arrows that board tasks run (docs/workflows.md). The first
  by `position` is the default for new tasks. A new workflow starts as a copy of another.
  Each save of its graph bumps `version` (an editor saving over a newer version is
  refused), records how many problems it was saved with (tasks run none with problems) and
  keeps the graph as that `Version`; a new workflow starts at version 1.
  """
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Workflows,
    data_layer: AshPostgres.DataLayer

  alias Weworkai.Workflows.Workflow.{Changes, Template, Validations}

  postgres do
    table "workflows"
    repo Weworkai.Repo
  end

  actions do
    defaults [:read]

    # The command palette's candidates: `pattern` is a `Weworkai.Fuzzy.pattern/1`.
    read :search do
      argument :pattern, :string, allow_nil?: false
      filter expr(ilike(name, ^arg(:pattern)))
      prepare build(sort: [position: :asc, inserted_at: :asc], limit: 20)
    end

    read :list do
      prepare build(sort: [position: :asc, inserted_at: :asc], load: [:block_count, :task_count])
    end

    read :templates do
      filter expr(not is_nil(template))
      prepare build(sort: [position: :asc, inserted_at: :asc], load: [:block_count])
    end

    create :create do
      accept [:name]
      # The workflow whose blocks and arrows the new one starts with; nil = the default.
      argument :source_id, :uuid
      # Starts with no blocks at all instead of a copy.
      argument :empty, :boolean, default: false
      change Changes.Append
      change Changes.CopyGraph

      change after_action(fn _changeset, workflow, _context ->
               Weworkai.Workflows.record_version!(workflow)
               {:ok, workflow}
             end)
    end

    update :rename do
      accept [:name]
    end

    update :reposition do
      accept [:position]
    end

    # Its graph was replaced (Workflows.save_graph/2), over the version the editor started from.
    update :record_graph do
      accept [:problem_count]
      change optimistic_lock(:version)
    end

    # Its problems changed without an edit (an employee its blocks name was removed or
    # changed role): the graph and its version stay as they are.
    update :recount do
      accept [:problem_count]
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      validate Validations.Unused
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 100
    end

    attribute :position, :integer, allow_nil?: false, public?: true, default: 0

    # Set by the migrations that seed the examples; no action writes it.
    attribute :template, Template, public?: true
    attribute :version, :integer, allow_nil?: false, public?: true, default: 1

    attribute :problem_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    timestamps()
  end

  relationships do
    has_many :nodes, Weworkai.Workflows.Node
    has_many :edges, Weworkai.Workflows.Edge
    has_many :versions, Weworkai.Workflows.Version
    has_many :tasks, Weworkai.Board.Task
  end

  aggregates do
    count :block_count, :nodes do
      filter expr(kind != :group)
    end

    count :task_count, :tasks
  end
end
