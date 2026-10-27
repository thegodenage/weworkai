defmodule Weworkai.Scheduling.ScheduledJob.State do
  use Ash.Type.Enum, values: [:pending, :started, :completed, :failed, :canceled]
end
