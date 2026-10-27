defmodule Weworkai.Board.TaskMessage.Author do
  use Ash.Type.Enum, values: [:human, :agent]
end
