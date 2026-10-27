defmodule Weworkai.Scheduling.Job.Status do
  use Ash.Type.Enum,
    values: [:before_start, :on_start, :in_progress, :done, :canceled, :on_hold, :failed]
end
