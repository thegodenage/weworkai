defmodule Weworkai.Agents.Agent.Role do
  use Ash.Type.Enum,
    values: [planner: [], coder: [], reviewer: [], qa: [label: "Docker reviewer"], custom: []]

  @read_only [:planner, :reviewer]

  @default_prompts %{
    planner: """
    Always write the code changes in the plan if there are any: for each change, show the \
    code you will write and the file it belongs to.\
    """
  }

  @doc """
  The profile runs of this role get from the provider; the bridge maps it to what the
  agent's container may reach and write (see bin/claude_bridge).
  """
  def profile(role), do: role

  @doc "Whether agents in this role get the repository mounted read-only."
  def read_only?(role), do: role in @read_only

  @doc "Prompt a new agent in this role starts with; nil when the role has none."
  def default_prompt(role), do: Map.get(@default_prompts, role)
end
