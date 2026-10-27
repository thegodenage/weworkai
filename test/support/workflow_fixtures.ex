defmodule Weworkai.WorkflowFixtures do
  @moduledoc "Finds blocks of a task's workflow for tests, by the label they are drawn with."
  alias Weworkai.Workflows

  @doc "The id of the block labelled `label` in the task's workflow."
  def block_id(%{workflow_id: workflow_id}, label) do
    workflow_id
    |> Workflows.graph!()
    |> Map.fetch!(:nodes)
    |> Map.values()
    |> Enum.find(&(&1.label == label))
    |> Map.fetch!(:id)
  end
end
