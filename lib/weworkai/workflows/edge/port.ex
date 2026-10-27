defmodule Weworkai.Workflows.Edge.Port do
  @moduledoc "The side of a block an arrow's end is drawn on."
  use Ash.Type.Enum, values: [:top, :right, :bottom, :left]
end
