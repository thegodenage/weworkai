defmodule Weworkai.Workflows.Node.Color do
  @moduledoc "The colour a group's rectangle is drawn in, in the editor; it means nothing to the engine."
  use Ash.Type.Enum, values: [:slate, :blue, :violet, :green, :amber, :rose]
end
