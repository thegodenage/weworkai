defmodule Weworkai.Workflows.Workflow.Changes.Append do
  @moduledoc "A new workflow goes to the end of the list, so the default stays the default."
  use Ash.Resource.Change

  alias Weworkai.Workflows.Workflow

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      last =
        Workflow
        |> Ash.Query.sort(position: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!()

      position = if last, do: last.position + 1, else: 0
      Ash.Changeset.force_change_attribute(changeset, :position, position)
    end)
  end
end
