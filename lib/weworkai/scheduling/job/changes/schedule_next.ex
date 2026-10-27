defmodule Weworkai.Scheduling.Job.Changes.ScheduleNext do
  @moduledoc "Queues the jobs waiting on this one, in the same transaction that finishes it."
  use Ash.Resource.Change

  alias Weworkai.Scheduling

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, job ->
      job = Ash.load!(job, :next_jobs)

      job.next_jobs
      |> Enum.filter(&(&1.status == :before_start))
      |> Enum.each(&Scheduling.schedule_job!(%{job_id: &1.id}))

      {:ok, job}
    end)
  end
end
