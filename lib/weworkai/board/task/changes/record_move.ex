defmodule Weworkai.Board.Task.Changes.RecordMove do
  @moduledoc """
  A human moving the task to another column is a point on its audit timeline, on the
  block it was on. It is labelled with the column the human chose, read before the
  workflow's transition may set another status (a human block, a column block).
  """
  use Ash.Resource.Change

  alias Weworkai.Board
  alias Weworkai.Board.Task.Status

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :status) do
      node_id = changeset.data.current_node_id
      chosen = Ash.Changeset.get_attribute(changeset, :status)

      Ash.Changeset.after_action(changeset, fn _changeset, task ->
        Board.record_event!(%{
          task_id: task.id,
          kind: :move,
          label: "Moved to #{Status.label(chosen)}",
          node_id: node_id
        })

        {:ok, task}
      end)
    else
      changeset
    end
  end
end
