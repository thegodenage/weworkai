defmodule WeworkaiWeb.UsageComponents do
  @moduledoc "What agent runs used (`Weworkai.Agents.Usage`), the way pages write it."
  use WeworkaiWeb, :html

  alias Weworkai.Agents.{Budget, Usage}

  @doc "18.4k, 1.2M."
  def tokens(count) when count < 1_000, do: Integer.to_string(count)
  def tokens(count) when count < 1_000_000, do: "#{Float.round(count / 1_000, 1)}k"
  def tokens(count), do: "#{Float.round(count / 1_000_000, 1)}M"

  defdelegate cost(usd), to: Usage, as: :usd

  @doc "A total or one run's usage, its breakdown in the title."
  attr :usage, :map, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def usage(assigns) do
    ~H"""
    <span class={["font-mono text-xs tabular-nums", @class]} title={breakdown(@usage)} {@rest}>
      {tokens(Usage.tokens(@usage))} tok · {cost(@usage.cost_usd)}
    </span>
    """
  end

  defp breakdown(usage) do
    "input #{tokens(usage.input_tokens)} · output #{tokens(usage.output_tokens)} · " <>
      "cache read #{tokens(usage.cache_read_tokens)} · " <>
      "cache write #{tokens(usage.cache_creation_tokens)} · #{usage.turns} turns"
  end

  @doc "Spend against a cap (`Weworkai.Agents.Budget`): a ten-cell bar, `$spent / $cap` and the share."
  attr :budget, Budget, required: true
  attr :rest, :global

  def budget_meter(assigns) do
    assigns =
      assign(assigns,
        mark: mark(assigns.budget),
        percent: round(Budget.share(assigns.budget) * 100)
      )

    ~H"""
    <span class="budget-meter" data-mark={@mark} title={Budget.describe(@budget)} {@rest}>
      <span class="budget-track" aria-hidden="true">
        <span class="budget-fill" style={"width: #{min(@percent, 100)}%"}></span>
      </span>
      <span>{cost(@budget.spent)} / {cost(@budget.cap)}</span>
      <span class="budget-percent">{@percent}%</span>
    </span>
    """
  end

  defp mark(budget) do
    cond do
      Budget.reached?(budget) -> "reached"
      Budget.warning?(budget) -> "warning"
      true -> "ok"
    end
  end

  @doc "Spend per agent over a period: a row per agent, the costliest first."
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :rows, :list, required: true, doc: "`{agent, total}`, as `Usage.by_agent/1` returns"

  def usage_table(assigns) do
    ~H"""
    <section id={@id} class="orpheus-card overflow-x-auto">
      <h2 class="border-b border-(--orpheus-border) px-4 py-2 text-[11px] font-medium tracking-wider text-(--orpheus-text-muted) uppercase">
        {@title}
      </h2>
      <table class="w-full text-sm">
        <thead class="text-left text-[11px] tracking-wider text-(--orpheus-text-muted) uppercase">
          <tr>
            <th class="px-4 py-2 font-medium">Agent</th>
            <th class="px-4 py-2 text-right font-medium">Runs</th>
            <th class="px-4 py-2 text-right font-medium">Input</th>
            <th class="px-4 py-2 text-right font-medium">Output</th>
            <th class="px-4 py-2 text-right font-medium">Cache</th>
            <th class="px-4 py-2 text-right font-medium">Cost</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-(--orpheus-border) font-mono tabular-nums">
          <tr :for={{agent, total} <- @rows} id={"#{@id}-#{agent.id}"}>
            <td class="px-4 py-2 font-sans">
              {if agent.employee, do: agent.employee.name, else: "Agent"}
            </td>
            <td class="px-4 py-2 text-right">{total.runs}</td>
            <td class="px-4 py-2 text-right">{tokens(total.input_tokens)}</td>
            <td class="px-4 py-2 text-right">{tokens(total.output_tokens)}</td>
            <td class="px-4 py-2 text-right">
              {tokens(total.cache_read_tokens + total.cache_creation_tokens)}
            </td>
            <td class="px-4 py-2 text-right">{cost(total.cost_usd)}</td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end
end
