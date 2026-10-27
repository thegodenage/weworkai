defmodule Weworkai.Board.TaskEvent.Kind do
  @moduledoc """
  Which step a `TaskEvent` records: a human's (`:upgrade`: moved to a newer workflow
  version), a spending cap crossed (`:budget`), the scheduler stopping a run that went
  silent (`:stalled`) or ran past its turn timeout (`:timed_out`), or the task's last open
  blocker closing (`:unblocked`).
  """
  use Ash.Type.Enum,
    values: [
      :move,
      :approve,
      :comment,
      :answer,
      :decide,
      :continue,
      :budget,
      :stalled,
      :timed_out,
      :unblocked,
      :upgrade
    ]
end
