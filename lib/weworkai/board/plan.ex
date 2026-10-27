defmodule Weworkai.Board.Plan do
  @moduledoc "A planner's plan (the `plan` schema in docs/workflow.md)."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :summary, :string, allow_nil?: false, public?: true, constraints: [trim?: false]

    attribute :steps, {:array, Weworkai.Board.Plan.Step},
      allow_nil?: false,
      public?: true,
      default: []

    attribute :questions, {:array, Weworkai.Board.Question},
      allow_nil?: false,
      public?: true,
      default: []
  end
end
