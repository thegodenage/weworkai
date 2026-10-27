defmodule Weworkai.Board.Task.Changes.UpgradeWorkflow do
  @moduledoc """
  Pins the task to its workflow's latest version where the block it is on still is
  (`Workflows.upgrade/1`); its place and counts carry over, as block and arrow ids do. A
  point on its audit timeline records the move.
  """
  use Ash.Resource.Change

  alias Weworkai.{Board, Workflows}
  alias Weworkai.Workflows.Errors.Refused

  @impl true
  def change(changeset, _opts, _context) do
    task = changeset.data

    case Workflows.upgrade(task) do
      {:ok, number} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:workflow_version, number)
        |> Ash.Changeset.after_action(fn _changeset, upgraded ->
          Board.record_event!(%{
            task_id: upgraded.id,
            kind: :upgrade,
            label: "Moved from v#{task.workflow_version} to v#{number}",
            node_id: task.current_node_id
          })

          {:ok, upgraded}
        end)

      {:error, reason} ->
        Ash.Changeset.add_error(changeset, Refused.exception(reason: reason))
    end
  end
end
