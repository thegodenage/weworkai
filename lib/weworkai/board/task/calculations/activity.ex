defmodule Weworkai.Board.Task.Calculations.Activity do
  @moduledoc "`Task.activity`: one query for all tasks' working jobs, however many are loaded."
  use Ash.Resource.Calculation

  alias Weworkai.Board.Task.Activity
  alias Weworkai.Scheduling.Job

  @impl true
  def load(_query, _opts, _context),
    do: [
      working_jobs:
        Ash.Query.select(Job, [:stage, :status, :started_at, :inserted_at, :updated_at])
    ]

  @impl true
  def calculate(tasks, _opts, _context), do: Enum.map(tasks, &Activity.from_jobs(&1.working_jobs))
end
