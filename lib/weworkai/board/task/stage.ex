defmodule Weworkai.Board.Task.Stage do
  @moduledoc "Which agent stage of the workflow a task is in; nil outside the workflow."
  use Ash.Type.Enum,
    values: [planning: [], coding: [], code_review: [label: "Code review"], qa: [label: "QA"]]
end
