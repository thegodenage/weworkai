defmodule Weworkai.Agents.Usage do
  @moduledoc """
  A total of `Weworkai.Agents.RunUsage` rows: a run's, a task's, an agent's over a period.
  """
  defstruct runs: 0,
            input_tokens: 0,
            output_tokens: 0,
            cache_read_tokens: 0,
            cache_creation_tokens: 0,
            cost_usd: Decimal.new(0),
            duration_ms: 0,
            turns: 0

  @type t :: %__MODULE__{}

  @counts [
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_creation_tokens,
    :duration_ms,
    :turns
  ]

  @spec total([Ash.Resource.record()]) :: t()
  def total(usages), do: Enum.reduce(usages, %__MODULE__{}, &add/2)

  defp add(usage, total) do
    @counts
    |> Map.new(&{&1, Map.fetch!(total, &1) + Map.fetch!(usage, &1)})
    |> Map.merge(%{runs: total.runs + 1, cost_usd: Decimal.add(total.cost_usd, usage.cost_usd)})
    |> then(&struct!(total, &1))
  end

  @doc "Every token the runs used, cached ones included."
  def tokens(usage),
    do:
      usage.input_tokens + usage.output_tokens + usage.cache_read_tokens +
        usage.cache_creation_tokens

  @doc "Cents and below need the extra places: $0.0912, $12.35; nothing is $0."
  def usd(amount) do
    if Decimal.eq?(amount, 0), do: "$0", else: nonzero_usd(amount)
  end

  defp nonzero_usd(amount) do
    places = if Decimal.lt?(amount, 1), do: 4, else: 2
    "$" <> (amount |> Decimal.round(places) |> Decimal.to_string(:normal))
  end

  @doc "Totals per agent, the costliest first, as `{agent, total}`. Needs `agent` loaded."
  def by_agent(usages) do
    usages
    |> Enum.group_by(& &1.agent_id)
    |> Enum.map(fn {_id, [first | _] = usages} -> {first.agent, total(usages)} end)
    |> Enum.sort_by(fn {_agent, total} -> total.cost_usd end, {:desc, Decimal})
  end
end
