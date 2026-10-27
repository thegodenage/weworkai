defmodule Weworkai.Board.TaskMessage.Kind do
  use Ash.Type.Enum,
    values: [
      :comment,
      :answer,
      :plan,
      :outcome,
      :findings,
      :system,
      :restart,
      :question,
      :reply,
      :unanswered,
      :decision
    ]
end
