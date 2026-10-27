defmodule Weworkai.Board.Task.Calculations.CurrentNode do
  @moduledoc """
  The block a task is on, as the workflow version it runs draws it: a block the latest
  graph removed is still where a task pinned to an older version is.
  """
  use Ash.Resource.Calculation

  alias Weworkai.Workflows

  @impl true
  def load(_query, _opts, _context), do: [:workflow_id, :workflow_version, :current_node_id]

  @impl true
  def calculate(tasks, _opts, _context) do
    nodes =
      tasks
      |> Enum.filter(& &1.current_node_id)
      |> Enum.map(&{&1.workflow_id, &1.workflow_version})
      |> Enum.uniq()
      |> Map.new(fn {workflow_id, number} = key ->
        {key, Workflows.version_nodes(workflow_id, number)}
      end)

    Enum.map(tasks, fn task ->
      get_in(nodes, [{task.workflow_id, task.workflow_version}, task.current_node_id])
    end)
  end
end
