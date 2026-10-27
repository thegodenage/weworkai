defmodule Weworkai.Board.Task.Changes.Transition do
  @moduledoc """
  A human's action moves the task through its workflow graph: `step` names the
  `Weworkai.Workflows.Engine` function that builds the transition from the task and the
  action's arguments. It is built before the transaction, since it may ask the bridge for
  a worktree or a diff; a refusal (an agent that can't run, no reviewer block, a workflow
  with problems, in the version the task runs…) fails the action. Inside it, the task's active jobs are canceled first (stopping their sessions),
  so nothing competes with the transition's new job; a transition that changes nothing
  (the task's agent already works on it) leaves them be.
  """
  use Ash.Resource.Change

  alias Weworkai.Scheduling
  alias Weworkai.Workflows
  alias Weworkai.Workflows.{Engine, Transition}
  alias Weworkai.Workflows.Errors.Refused

  @impl true
  def change(changeset, opts, _context) do
    step = Keyword.fetch!(opts, :step)

    changeset
    |> Ash.Changeset.before_transaction(&build(&1, step))
    |> Ash.Changeset.after_action(fn changeset, task ->
      transition = changeset.context.transition

      if transition != %Transition{},
        do: Enum.each(Scheduling.active_jobs!(task.id), &Scheduling.cancel_job!/1)

      Engine.record(task, transition)
      {:ok, task}
    end)
  end

  defp build(%{valid?: false} = changeset, _step), do: changeset

  defp build(changeset, step) do
    with :ok <- runnable(changeset.data, step, changeset.arguments),
         {:ok, transition} <- apply(Engine, step, [changeset.data, changeset.arguments]) do
      changeset
      |> Ash.Changeset.force_change_attributes(transition.task)
      |> Ash.Changeset.put_context(:transition, transition)
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  # A version with problems runs nothing; Continue can still mark the task done.
  defp runnable(_task, :continue, %{target: "done"}), do: :ok

  defp runnable(task, _step, _arguments) do
    case Workflows.running!(task) do
      %{problems: []} -> :ok
      running -> {:error, Refused.exception(reason: Workflows.not_runnable(running))}
    end
  end
end
