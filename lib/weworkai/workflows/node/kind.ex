defmodule Weworkai.Workflows.Node.Kind do
  @moduledoc """
  What entering a block does (docs/workflows.md): an agent runs, a human decides, the task
  moves to a board column, a group starts its first block, or a triage block sends the task
  on by the worst severity among the round's open findings.
  """
  use Ash.Type.Enum,
    values: [
      agent: [label: "Agent"],
      human: [label: "Human"],
      column: [label: "Column"],
      group: [label: "Group"],
      triage: [label: "Triage"]
    ]
end
