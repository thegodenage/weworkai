defmodule Weworkai.Workflows.Workflow.Template do
  @moduledoc """
  Which seeded example a workflow is (docs/workflows.md, "Templates"): "New from template"
  copies it. Templates are ordinary workflows otherwise, so editing one changes what later
  copies start with; copies are never templates themselves.
  """
  use Ash.Type.Enum,
    values: [
      default: [
        label: "Default",
        description:
          "Planner, plan approval, coder, then a code reviewer and a docker reviewer; findings go back to the coder up to three times."
      ],
      double_review: [
        label: "Double review",
        description:
          "Like the default, but the code and docker reviewers run twice in a row after every change to the code."
      ]
    ]
end
