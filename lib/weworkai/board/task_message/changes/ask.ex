defmodule Weworkai.Board.TaskMessage.Changes.Ask do
  @moduledoc """
  A human's question about a task is saved with the job that answers it
  (`Engine.ask_job/3`): a read-only run beside the task's workflow, so the task keeps its
  status, stage and agents. With no planner at all while a connector is connected, the
  default planner (`Organization.DefaultAgent`) is made to answer. Refused when no agent
  can answer.
  """
  use Ash.Resource.Change

  alias Weworkai.{Agents, Board, Scheduling}
  alias Weworkai.Organization.DefaultAgent
  alias Weworkai.Workflows.Engine

  @set_up "set up a planner or a reviewer (model and connector) on the Employees page."

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    # Making the default planner asks the connector for its models: outside the transaction.
    |> Ash.Changeset.before_transaction(fn changeset ->
      Ash.Changeset.put_context(changeset, :answerer, Engine.answerer() || default_planner())
    end)
    |> Ash.Changeset.before_action(fn changeset ->
      case changeset.context.answerer do
        {:error, message} -> Ash.Changeset.add_error(changeset, field: :body, message: message)
        _agent -> changeset
      end
    end)
    |> Ash.Changeset.after_action(fn changeset, question ->
      task = Board.get_task!(question.task_id)
      Scheduling.create_job!(Engine.ask_job(task, changeset.context.answerer, question.body))
      {:ok, question}
    end)
  end

  defp default_planner do
    case DefaultAgent.provision(:planner) do
      {:ok, agent} ->
        if Agents.missing_setup(agent),
          do: {:error, "No agent can answer yet: " <> @set_up},
          else: agent

      :none ->
        {:error, "No agent can answer yet: " <> @set_up}

      {:error, reason} ->
        {:error, "No agent can answer yet: no planner agent, and #{reason}"}
    end
  end
end
