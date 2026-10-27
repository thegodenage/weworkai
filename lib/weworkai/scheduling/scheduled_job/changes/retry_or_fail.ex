defmodule Weworkai.Scheduling.ScheduledJob.Changes.RetryOrFail do
  @moduledoc """
  Retry policy for a failed attempt: queue the next attempt with exponential backoff, or
  fail the job once `@max_attempts` are used. The retry is a row, so it survives restarts.
  """
  use Ash.Resource.Change

  alias Weworkai.Scheduling

  @max_attempts 3
  @base_backoff_seconds 30

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, attempt ->
      job = Ash.load!(attempt, :job).job

      if attempt.attempt < @max_attempts do
        Scheduling.schedule_job!(%{
          job_id: job.id,
          attempt: attempt.attempt + 1,
          run_at: DateTime.add(DateTime.utc_now(), backoff_seconds(attempt.attempt))
        })
      else
        Scheduling.fail_job!(job)
      end

      {:ok, attempt}
    end)
  end

  defp backoff_seconds(attempt), do: @base_backoff_seconds * 2 ** (attempt - 1)
end
