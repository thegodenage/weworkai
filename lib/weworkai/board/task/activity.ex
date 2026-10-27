defmodule Weworkai.Board.Task.Activity do
  @moduledoc """
  What an agent is doing on a task right now, read from the task's working jobs
  (`Task.working_jobs`): the job's stage (a workflow stage, `:ask` for a question, nil for
  a custom agent running the task as-is) and whether it is `:running` (the scheduler
  picked it up) or `:queued` (waiting for the scheduler or for the job before it), and
  `since` when: its run started (or it was picked up), or it was queued.
  """
  @enforce_keys [:stage, :state]
  defstruct [:stage, :state, :since]

  @type t :: %__MODULE__{
          stage: atom() | nil,
          state: :running | :queued,
          since: DateTime.t() | nil
        }

  @running [:on_start, :in_progress]

  @doc "Job statuses that count: held jobs don't, nothing runs until they are resumed."
  def job_statuses, do: [:before_start | @running]

  @doc """
  The job that says most about the task: the workflow's before a question (so
  `workflow?/1` is exact), then a running one before a queued one. nil when no job is
  working.
  """
  @spec from_jobs([Ash.Resource.record()]) :: t() | nil
  def from_jobs([]), do: nil

  def from_jobs(jobs) do
    job = Enum.min_by(jobs, &{&1.stage == :ask, &1.status not in @running})
    running? = job.status in @running

    %__MODULE__{
      stage: job.stage,
      state: if(running?, do: :running, else: :queued),
      since: if(running?, do: job.started_at || job.updated_at, else: job.inserted_at)
    }
  end

  @doc "An agent works on the task's own workflow, not only on a question about it."
  @spec workflow?(t() | nil) :: boolean()
  def workflow?(%__MODULE__{stage: :ask}), do: false
  def workflow?(%__MODULE__{}), do: true
  def workflow?(nil), do: false
end
