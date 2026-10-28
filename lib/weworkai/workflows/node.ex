defmodule Weworkai.Workflows.Node do
  @moduledoc """
  A block of a workflow graph. Its kind decides what entering it does; an agent block names
  a concrete agent employee or only a role ("any planner"), a human block a concrete human
  or nobody ("any human"). Written only through `Weworkai.Workflows.save_graph/2`, whose
  `Graph.validate/3` checks the whole graph first.
  """
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Workflows,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "workflow_nodes"
    repo Weworkai.Repo

    references do
      reference :workflow, on_delete: :delete
      # A removed employee leaves its block empty; the engine hands the task to a human there.
      reference :employee, on_delete: :nilify
      reference :group, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :id,
        :workflow_id,
        :kind,
        :employee_id,
        :agent_role,
        :column_status,
        :group_id,
        :label,
        :x,
        :y,
        :width,
        :height,
        :start,
        :color,
        :prompt,
        :stall_timeout_minutes,
        :turn_timeout_minutes,
        :merge_branch
      ]
    end
  end

  attributes do
    # Kept across saves, so tasks on a block keep their place when the graph is edited.
    uuid_primary_key :id, writable?: true

    attribute :kind, Weworkai.Workflows.Node.Kind, allow_nil?: false, public?: true
    attribute :agent_role, Weworkai.Agents.Agent.Role, public?: true
    attribute :column_status, Weworkai.Board.Task.Status, public?: true

    attribute :label, :string do
      allow_nil? false
      public? true
      constraints max_length: 100
    end

    attribute :x, :integer, allow_nil?: false, public?: true, default: 0
    attribute :y, :integer, allow_nil?: false, public?: true, default: 0
    attribute :width, :integer, public?: true
    attribute :height, :integer, public?: true
    attribute :start, :boolean, allow_nil?: false, public?: true, default: false
    attribute :color, Weworkai.Workflows.Node.Color, public?: true

    # An agent block's own instructions, added to its agent's prompt in this workflow only.
    attribute :prompt, :string do
      public? true
      constraints max_length: 20_000
    end

    # An agent block's limits on each run (`Weworkai.Scheduling.Timeout`); nil keeps the job's default.
    attribute :stall_timeout_minutes, :integer, public?: true, constraints: [min: 1, max: 1440]
    attribute :turn_timeout_minutes, :integer, public?: true, constraints: [min: 1, max: 1440]

    # A merger block's target branch; nil merges into the branch checked out in the repository.
    attribute :merge_branch, :string do
      public? true
      constraints max_length: 255
    end
  end

  relationships do
    belongs_to :workflow, Weworkai.Workflows.Workflow, allow_nil?: false, public?: true
    belongs_to :employee, Weworkai.Organization.Employee, public?: true
    belongs_to :group, __MODULE__, public?: true
  end
end
