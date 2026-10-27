defmodule Weworkai.Workflows.Workflow.Changes.CopyGraph do
  @moduledoc """
  A new workflow starts with a copy of another's blocks and arrows (the default's unless
  `source_id` names one), under new ids, so the two can be edited apart, and its problem
  count; or with none at all when `empty` is set, which is a problem ("Add a first block").
  """
  use Ash.Resource.Change

  alias Weworkai.Workflows

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_argument(changeset, :empty),
      do: Ash.Changeset.force_change_attribute(changeset, :problem_count, 1),
      else: copy(changeset)
  end

  defp copy(changeset) do
    source =
      case Ash.Changeset.get_argument(changeset, :source_id) do
        nil -> Workflows.default_workflow!()
        id -> Workflows.get_workflow!(id)
      end

    changeset
    |> Ash.Changeset.force_change_attribute(:problem_count, source.problem_count)
    |> Ash.Changeset.after_action(fn _changeset, workflow ->
      Workflows.copy_graph!(source, workflow)
      {:ok, workflow}
    end)
  end
end
