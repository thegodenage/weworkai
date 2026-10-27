defmodule Weworkai.Board.Task.Changes.SwitchWorkflow do
  @moduledoc """
  A task given another workflow starts that one afresh, on its latest version: its place
  and counts belong to the old graph, and an agent working on the old graph's block is
  stopped.
  """
  use Ash.Resource.Change

  alias Weworkai.{Scheduling, Workflows}

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :workflow_id) do
      changeset
      |> Ash.Changeset.force_change_attributes(
        current_node_id: nil,
        workflow_version:
          Workflows.get_workflow!(Ash.Changeset.get_attribute(changeset, :workflow_id)).version,
        edge_counts: %{},
        node_counts: %{}
      )
      |> Ash.Changeset.after_action(fn _changeset, task ->
        Enum.each(Scheduling.active_jobs!(task.id), &Scheduling.cancel_job!/1)
        {:ok, task}
      end)
    else
      changeset
    end
  end
end
