defmodule Weworkai.Board.Task.Changes.InheritParent do
  @moduledoc """
  A sub-task works in its parent's repository and runs its parent's workflow (on its latest
  version, `Changes.DefaultWorkflow`).
  """
  use Ash.Resource.Change

  alias Weworkai.Board

  @impl true
  def change(changeset, _opts, _context) do
    parent = Board.get_task!(Ash.Changeset.get_attribute(changeset, :parent_id), load: [])

    Ash.Changeset.force_change_attributes(changeset, %{
      repository: parent.repository,
      workflow_id: parent.workflow_id
    })
  end
end
