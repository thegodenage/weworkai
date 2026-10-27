defmodule Weworkai.Board.Finding do
  @moduledoc """
  A problem a reviewer found (the `findings` schema in docs/workflow.md). `source` and
  `block_id` (the workflow block whose run found it) are set by the workflow, so findings
  of the code reviewer and the docker reviewer stay apart, and a block reviewing again in
  the same round replaces its own.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :source, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:reviewer, :qa]]

    attribute :id, :string, allow_nil?: false, public?: true
    attribute :block_id, :string, public?: true

    attribute :severity, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:high, :medium, :low]]

    attribute :title, :string, allow_nil?: false, public?: true
    attribute :path, :string, public?: true
    attribute :line, :integer, public?: true
    attribute :details, :string, public?: true, constraints: [trim?: false]
    attribute :reproduction, :string, public?: true, constraints: [trim?: false]
    attribute :evidence, :string, public?: true, constraints: [trim?: false]
  end
end
