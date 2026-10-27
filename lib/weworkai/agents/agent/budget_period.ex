defmodule Weworkai.Agents.Agent.BudgetPeriod do
  @moduledoc "What an agent's budget covers: its runs since the start of today or of this week (UTC, weeks from Monday)."
  use Ash.Type.Enum, values: [day: [label: "Daily"], week: [label: "Weekly"]]

  @doc "When the period that `now` falls in began."
  def start(:day, now), do: midnight(DateTime.to_date(now))
  def start(:week, now), do: midnight(Date.beginning_of_week(DateTime.to_date(now)))

  defp midnight(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
end
