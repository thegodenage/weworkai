defmodule Weworkai.Board.Task.Changes.DefaultWorkflow do
  @moduledoc """
  A task created without a workflow runs the default one (the first in the list); either
  way it is pinned to its workflow's latest version.
  """
  use Ash.Resource.Change

  alias Weworkai.Workflows

  @impl true
  def change(changeset, _opts, _context) do
    workflow =
      case Ash.Changeset.get_attribute(changeset, :workflow_id) do
        nil -> Workflows.default_workflow!()
        id -> Workflows.get_workflow!(id)
      end

    Ash.Changeset.force_change_attributes(changeset,
      workflow_id: workflow.id,
      workflow_version: workflow.version
    )
  end
end
