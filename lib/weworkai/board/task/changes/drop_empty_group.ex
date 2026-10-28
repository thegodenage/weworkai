defmodule Weworkai.Board.Task.Changes.DropEmptyGroup do
  @moduledoc """
  A group the task leaves (for another group, for none, or by being deleted) goes when the
  task was its last.
  """
  use Ash.Resource.Change

  alias Weworkai.Board

  @impl true
  def change(%{data: %{group_id: nil}} = changeset, _opts, _context), do: changeset

  def change(changeset, _opts, _context) do
    group_id = changeset.data.group_id

    Ash.Changeset.after_action(changeset, fn _changeset, task ->
      case Board.get_task_group(group_id, load: :task_count) do
        {:ok, %{task_count: 0} = group} -> Board.destroy_task_group!(group)
        _kept -> :ok
      end

      {:ok, task}
    end)
  end
end
