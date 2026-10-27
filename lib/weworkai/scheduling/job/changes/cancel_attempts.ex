defmodule Weworkai.Scheduling.Job.Changes.CancelAttempts do
  @moduledoc """
  Cancels the job's queued and started attempts, stopping the agent session of a started
  one unless it was already stopped from the UI.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Weworkai.{Agents, Scheduling}
  alias Weworkai.Scheduling.ScheduledJob

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, job ->
      ScheduledJob
      |> Ash.Query.filter(job_id == ^job.id and state in [:pending, :started])
      |> Ash.Query.load(:agent_run)
      |> Ash.read!()
      |> Enum.each(&cancel/1)

      {:ok, job}
    end)
  end

  defp cancel(%{agent_run: %{stopped_at: nil} = run} = attempt) do
    Agents.stop_run!(run)
    Scheduling.mark_canceled!(attempt)
  end

  defp cancel(attempt), do: Scheduling.mark_canceled!(attempt)
end
