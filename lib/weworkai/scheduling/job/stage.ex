defmodule Weworkai.Scheduling.Job.Stage do
  @moduledoc """
  What a run's result is for: a workflow stage (`Weworkai.Board.Task.Stage`), or `ask`,
  a human's question about the task, answered beside the workflow without moving it.
  """
  use Ash.Type.Enum,
    values: [
      planning: [],
      coding: [],
      code_review: [label: "Code review"],
      qa: [label: "QA"],
      ask: [label: "Question"]
    ]
end
