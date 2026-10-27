defmodule Weworkai.Board.Question do
  @moduledoc "A decision an agent (planner or coder) needs from a human."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :id, :string, allow_nil?: false, public?: true
    attribute :question, :string, allow_nil?: false, public?: true
    attribute :options, {:array, :string}, allow_nil?: false, public?: true, default: []
  end
end
