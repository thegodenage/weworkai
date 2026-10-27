defmodule Weworkai.Board.Plan.Change do
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :path, :string, allow_nil?: false, public?: true
    # Unified diff; untrimmed, since whitespace is part of it.
    attribute :diff, :string, allow_nil?: false, public?: true, constraints: [trim?: false]
  end
end
