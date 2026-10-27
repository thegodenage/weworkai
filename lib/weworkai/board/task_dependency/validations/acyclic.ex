defmodule Weworkai.Board.TaskDependency.Validations.Acyclic do
  @moduledoc """
  A task can't wait on itself, directly or through the tasks its blocker waits on: the
  loop would never let any of them start.
  """
  use Ash.Resource.Validation

  require Ash.Query

  alias Weworkai.Board.TaskDependency

  @impl true
  def validate(changeset, _opts, _context) do
    blocked = Ash.Changeset.get_attribute(changeset, :blocked_id)
    blocker = Ash.Changeset.get_attribute(changeset, :blocker_id)

    if waits_on?([blocker], blocked, MapSet.new()) do
      {:error, field: :blocker_id, message: "would make these tasks wait on each other forever"}
    else
      :ok
    end
  end

  # Walks the blockers of `tasks` a level per query, looking for `target`.
  defp waits_on?([], _target, _seen), do: false

  defp waits_on?(tasks, target, seen) do
    if target in tasks do
      true
    else
      seen = MapSet.union(seen, MapSet.new(tasks))

      TaskDependency
      |> Ash.Query.filter(blocked_id in ^tasks)
      |> Ash.read!()
      |> Enum.map(& &1.blocker_id)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> waits_on?(target, seen)
    end
  end
end
