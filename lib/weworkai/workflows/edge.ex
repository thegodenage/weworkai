defmodule Weworkai.Workflows.Edge do
  @moduledoc """
  An arrow between two blocks: taken when the block it leaves ends with its `condition`
  (nil = any outcome no labelled arrow takes). `iterations` caps a self-loop's runs in a
  row, or a back arrow's traversals. `from_port` / `to_port` / `pinned` are for drawing
  only. Written only through `Weworkai.Workflows.save_graph/2`.
  """
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Workflows,
    data_layer: AshPostgres.DataLayer

  alias Weworkai.Workflows.Edge.Port

  postgres do
    table "workflow_edges"
    repo Weworkai.Repo

    references do
      reference :workflow, on_delete: :delete
      reference :from_node, on_delete: :delete
      reference :to_node, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :id,
        :workflow_id,
        :from_node_id,
        :to_node_id,
        :condition,
        :iterations,
        :from_port,
        :to_port,
        :pinned
      ]
    end
  end

  attributes do
    # Kept across saves, so a task's traversal counts survive an edit.
    uuid_primary_key :id, writable?: true

    attribute :condition, :string, public?: true, constraints: [max_length: 100]
    attribute :iterations, :integer, public?: true, constraints: [min: 1]
    attribute :from_port, Port, allow_nil?: false, public?: true, default: :right
    attribute :to_port, Port, allow_nil?: false, public?: true, default: :left
    # Its dots were chosen by hand: the editor keeps them when its blocks move.
    attribute :pinned, :boolean, allow_nil?: false, public?: true, default: false
  end

  relationships do
    belongs_to :workflow, Weworkai.Workflows.Workflow, allow_nil?: false, public?: true
    belongs_to :from_node, Weworkai.Workflows.Node, allow_nil?: false, public?: true
    belongs_to :to_node, Weworkai.Workflows.Node, allow_nil?: false, public?: true
  end
end
