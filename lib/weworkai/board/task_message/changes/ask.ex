defmodule Weworkai.Board.TaskMessage.Changes.Ask do
  @moduledoc """
  A human's question about a task is saved with the job that answers it
  (`Engine.ask_job/3`): a read-only run beside the task's workflow, so the task keeps its
  status, stage and agents. Refused when no agent can answer.
  """
  use Ash.Resource.Change

  alias Weworkai.{Board, Scheduling}
  alias Weworkai.Workflows.Engine

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      case Engine.answerer() do
        nil ->
          Ash.Changeset.add_error(changeset,
            field: :body,
            message:
              "No agent can answer yet: set up a planner or a reviewer (model and connector) on the Employees page."
          )

        agent ->
          Ash.Changeset.put_context(changeset, :answerer, agent)
      end
    end)
    |> Ash.Changeset.after_action(fn changeset, question ->
      task = Board.get_task!(question.task_id)
      Scheduling.create_job!(Engine.ask_job(task, changeset.context.answerer, question.body))
      {:ok, question}
    end)
  end
end
