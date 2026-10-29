defmodule Weworkai.Workflows.Workflow.Validations.Unused do
  @moduledoc """
  A workflow tasks or crons still run can't be deleted, nor the last one: every task and
  cron needs a workflow to run.
  """
  use Ash.Resource.Validation

  alias Weworkai.Workflows.Workflow

  @impl true
  def validate(changeset, _opts, _context) do
    workflow = Ash.load!(changeset.data, [:task_count, :cron_count])

    cond do
      workflow.task_count > 0 ->
        {:error, message: "#{tasks(workflow.task_count)} still use this workflow"}

      workflow.cron_count > 0 ->
        {:error, message: crons(workflow.cron_count)}

      Ash.count!(Workflow) == 1 ->
        {:error, message: "the last workflow can't be deleted"}

      true ->
        :ok
    end
  end

  defp tasks(1), do: "1 task"
  defp tasks(count), do: "#{count} tasks"

  defp crons(1), do: "1 cron still runs this workflow"
  defp crons(count), do: "#{count} crons still run this workflow"
end
