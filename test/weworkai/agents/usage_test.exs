defmodule Weworkai.Agents.UsageTest do
  use ExUnit.Case, async: true

  alias Weworkai.Agents.Usage

  defp row(agent, cost, tokens) do
    %{
      agent_id: agent.id,
      agent: agent,
      input_tokens: tokens,
      output_tokens: tokens,
      cache_read_tokens: tokens,
      cache_creation_tokens: tokens,
      cost_usd: Decimal.new(cost),
      duration_ms: 1_000,
      turns: 2
    }
  end

  test "nothing used is a zero total" do
    assert %Usage{runs: 0} = total = Usage.total([])
    assert Usage.tokens(total) == 0
    assert Decimal.equal?(total.cost_usd, 0)
  end

  test "totals add every count and the exact cost" do
    planner = %{id: "p"}
    total = Usage.total([row(planner, "0.1", 10), row(planner, "0.2", 5)])

    assert %Usage{runs: 2, input_tokens: 15, duration_ms: 2_000, turns: 4} = total
    assert Usage.tokens(total) == 60
    assert Decimal.equal?(total.cost_usd, "0.3")
  end

  test "per agent, the costliest first" do
    planner = %{id: "p"}
    coder = %{id: "c"}
    rows = [row(planner, "0.1", 1), row(coder, "0.5", 1), row(planner, "0.1", 1)]

    assert [{^coder, %Usage{runs: 1}}, {^planner, %Usage{runs: 2}}] = Usage.by_agent(rows)
  end
end
