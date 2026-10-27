defmodule Weworkai.Board.Task.Status do
  use Ash.Type.Enum,
    values: [:backlog, :todo, :in_progress, :review, :await_human_supervision, :done, :canceled]
end
