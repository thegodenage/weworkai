defmodule Weworkai.Board.Plan.Step do
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :id, :string, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true, constraints: [trim?: false]

    attribute :changes, {:array, Weworkai.Board.Plan.Change},
      allow_nil?: false,
      public?: true,
      default: []
  end
end
