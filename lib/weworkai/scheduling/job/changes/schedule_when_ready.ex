defmodule Weworkai.Scheduling.Job.Changes.ScheduleWhenReady do
  @moduledoc """
  Queues the job's first attempt in the same transaction, unless the previous job in the
  chain hasn't finished; `ScheduleNext` queues it then.
  """
  use Ash.Resource.Change

  alias Weworkai.Scheduling

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, job ->
      job = Ash.load!(job, :previous_job)

      if is_nil(job.previous_job) or job.previous_job.status == :done do
        Scheduling.schedule_job!(%{job_id: job.id})
      end

      {:ok, job}
    end)
  end
end
