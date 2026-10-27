defmodule Weworkai.Board.Task.Changes.CancelJobs do
  @moduledoc """
  A task a human moves out of the agents' columns (todo, in progress, review) takes its
  queued and running jobs with it. Canceling stops a running agent session, so its result
  is never applied to the task. Moving into review is `StartReview`'s to decide; questions
  being answered carry on.
  """
  use Ash.Resource.Change

  alias Weworkai.Scheduling

  @agent_statuses [:todo, :in_progress, :review]

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :status) and
         Ash.Changeset.get_attribute(changeset, :status) not in @agent_statuses do
      Ash.Changeset.after_action(changeset, fn _changeset, task ->
        Enum.each(Scheduling.active_jobs!(task.id), &Scheduling.cancel_job!/1)
        {:ok, task}
      end)
    else
      changeset
    end
  end
end
