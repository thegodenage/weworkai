defmodule Weworkai.Board.Task.Changes.DefaultWorkflow do
  @moduledoc """
  A task created without a workflow runs the default one (the first in the list); either
  way it is pinned to its workflow's latest version. A workflow that no longer exists is
  an error on the field.
  """
  use Ash.Resource.Change

  alias Weworkai.Workflows

  @impl true
  def change(changeset, _opts, _context) do
    workflow =
      case Ash.Changeset.get_attribute(changeset, :workflow_id) do
        nil -> {:ok, Workflows.default_workflow!()}
        id -> Workflows.get_workflow(id)
      end

    case workflow do
      {:ok, workflow} ->
        Ash.Changeset.force_change_attributes(changeset,
          workflow_id: workflow.id,
          workflow_version: workflow.version
        )

      # Deleted since the form offered it (in another tab, say): ask for another.
      {:error, _} ->
        Ash.Changeset.add_error(changeset,
          field: :workflow_id,
          message: "no longer exists, pick another"
        )
    end
  end
end
