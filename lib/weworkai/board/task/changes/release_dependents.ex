defmodule Weworkai.Board.Task.Changes.ReleaseDependents do
  @moduledoc """
  A blocker closing (done or canceled) frees the tasks that waited only on it: each gets a
  point on its timeline and a notification. Nothing needs restarting, their queued work
  was only held back by the scheduler (`Weworkai.Board.TaskDependency`).
  """
  use Ash.Resource.Change

  alias Weworkai.{Board, Notifications}
  alias Weworkai.Board.Task.Status

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, task ->
      task
      |> Ash.load!([dependents: [:blocked]], reuse_values?: false)
      |> Map.fetch!(:dependents)
      |> Enum.reject(& &1.blocked)
      |> Enum.each(&release(&1, task))

      {:ok, task}
    end)
  end

  defp release(dependent, blocker) do
    Board.record_event!(%{
      task_id: dependent.id,
      kind: :unblocked,
      label: "Unblocked by #{blocker.title}",
      node_id: dependent.current_node_id
    })

    Notifications.notify!(%{
      task_id: dependent.id,
      kind: :unblocked,
      title: "Unblocked: #{dependent.title}",
      body:
        "#{blocker.title} is #{String.downcase(Status.label(blocker.status))}; " <>
          "nothing blocks this task any more."
    })
  end
end
