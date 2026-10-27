defmodule Weworkai.Agents.Budget do
  @moduledoc """
  A spending cap and what the cost ledger (`Weworkai.Agents.RunUsage`) holds against it:
  a task's, over all its runs, or an agent's, over its runs this day or week
  (`Agent.BudgetPeriod`). A run that takes a budget past 80% or past its cap is noted on
  its task (an event and a notification). A spent budget lets no new run start: the
  scheduler refuses it and a human takes the task over, who can raise the cap and Continue.
  """
  alias Weworkai.Agents
  alias Weworkai.Agents.Agent.BudgetPeriod
  alias Weworkai.Agents.Errors.OverBudget
  alias Weworkai.Agents.Usage

  @enforce_keys [:owner, :cap, :spent]
  defstruct [:owner, :cap, :spent]

  @type owner :: :task | {:agent, name :: String.t(), BudgetPeriod.t()}
  @type t :: %__MODULE__{owner: owner(), cap: Decimal.t(), spent: Decimal.t()}

  @warning_share Decimal.new("0.8")

  @doc "The task's budget, nil when it has none."
  def task(%{budget_usd: nil}), do: nil

  def task(task) do
    %__MODULE__{owner: :task, cap: task.budget_usd, spent: spent(Agents.task_usage!(task.id))}
  end

  @doc "The agent's budget for the period `now` falls in, nil when it has none. Needs `employee` loaded."
  def agent(%{budget_usd: nil}, _now), do: nil

  def agent(agent, now) do
    since = BudgetPeriod.start(agent.budget_period, now)

    %__MODULE__{
      owner: {:agent, agent.employee.name, agent.budget_period},
      cap: agent.budget_usd,
      spent: spent(Agents.agent_usage_since!(agent.id, since))
    }
  end

  defp spent(usages), do: Usage.total(usages).cost_usd

  @doc "The budgets a job's runs count against: its task's and its agent's, those that are set."
  def of(job) do
    job = Ash.load!(job, [:task, agent: :employee], reuse_values?: true)
    Enum.reject([task(job.task), agent(job.agent, DateTime.utc_now())], &is_nil/1)
  end

  @doc "`:ok` when the job's run may start, else an error naming the budget it spent."
  def allow(job) do
    case Enum.find(of(job), &reached?/1) do
      nil -> :ok
      budget -> {:error, OverBudget.exception(budget: budget)}
    end
  end

  def reached?(budget), do: not Decimal.lt?(budget.spent, budget.cap)

  def warning?(budget),
    do: not Decimal.lt?(budget.spent, Decimal.mult(budget.cap, @warning_share))

  @doc "Spent per cap, 0 to 1 and beyond, for meters."
  def share(budget), do: budget.spent |> Decimal.div(budget.cap) |> Decimal.to_float()

  @doc """
  The mark (`:warning` at 80%, `:reached` at the cap) a run costing `cost` took the budget
  past, as `[{mark, budget}]`; `budget` already counts the run.
  """
  def crossed(budget, cost) do
    before = %{budget | spent: Decimal.sub(budget.spent, cost)}

    cond do
      reached?(budget) and not reached?(before) -> [{:reached, budget}]
      warning?(budget) and not warning?(before) -> [{:warning, budget}]
      true -> []
    end
  end

  @doc "\"This task has spent $0.0912 of its $0.05 budget.\""
  def describe(%{owner: :task} = budget),
    do: "This task has spent #{Usage.usd(budget.spent)} of its #{Usage.usd(budget.cap)} budget."

  def describe(%{owner: {:agent, name, period}} = budget),
    do:
      "#{name} has spent #{Usage.usd(budget.spent)} of a #{Usage.usd(budget.cap)} " <>
        "#{String.downcase(BudgetPeriod.label(period))} budget."

  @doc "Where a human raises it."
  def raise_hint(%{owner: :task}), do: "Raise the task's budget on its page, then Continue."

  def raise_hint(%{owner: {:agent, _name, _period}}),
    do: "Raise it on the Employees page, then Continue."
end
