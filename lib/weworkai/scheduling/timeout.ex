defmodule Weworkai.Scheduling.Timeout do
  @moduledoc """
  When a running agent has gone on too long: it wrote nothing for its job's
  `stall_timeout_minutes` (`:stalled`), or it has run for its `turn_timeout_minutes`
  in all (`:timed_out`). The scheduler stops such a run and retries the job
  (docs/scheduler.md, "Timeouts").
  """

  @enforce_keys [:kind, :minutes]
  defstruct [:kind, :minutes]

  @type t :: %__MODULE__{kind: :stalled | :timed_out, minutes: pos_integer()}

  @doc """
  The timeout a run started at `started_at` has exceeded as of `now`, or nil. `last_event_at`
  is when its session last wrote anything; nil when the connector doesn't say, which leaves
  only the turn timeout.
  """
  @spec exceeded(map(), DateTime.t(), DateTime.t() | nil, DateTime.t()) :: t() | nil
  def exceeded(job, started_at, last_event_at, now) do
    cond do
      past?(started_at, job.turn_timeout_minutes, now) ->
        %__MODULE__{kind: :timed_out, minutes: job.turn_timeout_minutes}

      last_event_at && past?(last_event_at, job.stall_timeout_minutes, now) ->
        %__MODULE__{kind: :stalled, minutes: job.stall_timeout_minutes}

      true ->
        nil
    end
  end

  @doc "Why the run was stopped, for the attempt's error and the people told about it."
  def reason(%__MODULE__{kind: :stalled, minutes: minutes}),
    do: "The agent wrote nothing for #{minutes(minutes)}, so its run was stopped."

  def reason(%__MODULE__{kind: :timed_out, minutes: minutes}),
    do: "The agent ran past its #{minutes(minutes)} turn timeout, so its run was stopped."

  defp past?(since, minutes, now), do: DateTime.diff(now, since) >= minutes * 60

  defp minutes(1), do: "1 minute"
  defp minutes(count), do: "#{count} minutes"
end
