defmodule Weworkai.Board.ProofOfWorkTest do
  use ExUnit.Case, async: true

  alias Weworkai.Agents.{Budget, Usage}
  alias Weworkai.Board.ProofOfWork

  @start ~U[2026-10-28 12:00:00Z]

  defp at(minutes), do: DateTime.add(@start, minutes, :minute)

  defp message(role, kind, body, minutes),
    do: %{author: :agent, agent_role: role, kind: kind, body: body, inserted_at: at(minutes)}

  defp usage(cost, duration_ms) do
    %{
      input_tokens: 10,
      output_tokens: 5,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      cost_usd: Decimal.new(cost),
      duration_ms: duration_ms,
      turns: 2
    }
  end

  defp attempt(stage, state, minutes, run_usage) do
    %{
      job: %{stage: stage},
      state: state,
      agent_run_id: "run-#{stage}-#{minutes}",
      agent_run: %{usage: run_usage},
      inserted_at: at(minutes),
      updated_at: at(minutes + 1)
    }
  end

  defp finding(source, severity), do: %{source: source, severity: severity}

  setup do
    task = %{
      budget_usd: Decimal.new("2"),
      findings: [finding(:qa, :high), finding(:qa, :low), finding(:qa, :low)]
    }

    messages = [
      message(:planner, :plan, "A plan.", 0),
      message(:coder, :outcome, "Implemented.", 5),
      message(:reviewer, :findings, "1 findings.", 10),
      %{author: :human, agent_role: nil, kind: :comment, body: "Fix it.", inserted_at: at(11)},
      message(:coder, :outcome, "Fixed.", 15),
      message(:reviewer, :findings, "0 findings.", 20),
      message(:qa, :findings, "3 findings.", 25)
    ]

    # Newest first, as the task's runs are read.
    attempts =
      Enum.reverse([
        attempt(:planning, :completed, 0, usage("0.10", 60_000)),
        attempt(:coding, :failed, 2, nil),
        attempt(:coding, :completed, 4, usage("0.40", 120_000)),
        attempt(:code_review, :completed, 9, usage("0.15", 30_000)),
        attempt(:coding, :completed, 14, usage("0.30", 90_000))
      ])

    usage = Usage.total(Enum.flat_map(attempts, &List.wrap(&1.agent_run.usage)))
    %{proof: ProofOfWork.new(task, messages, attempts, usage)}
  end

  test "counts the open findings per severity", %{proof: proof} do
    assert proof.findings == [high: 1, medium: 0, low: 2]
  end

  test "keeps each agent's latest report, with a reviewer's open findings", %{proof: proof} do
    assert [
             %{role: :coder, body: "Fixed.", open: nil},
             %{role: :reviewer, body: "0 findings.", open: 0},
             %{role: :qa, body: "3 findings.", open: 3}
           ] = proof.reports
  end

  test "sums runs per stage in the order they first ran", %{proof: proof} do
    assert [planning, coding, review] = proof.stages
    assert %{stage: :planning, runs: 1, failed: 0, duration_ms: 60_000} = planning

    assert %{stage: :coding, runs: 3, failed: 1, duration_ms: 210_000, state: :completed} =
             coding

    assert Decimal.eq?(coding.cost_usd, "0.70")
    assert coding.last_run_id == "run-coding-14"
    assert %{stage: :code_review, runs: 1} = review
  end

  test "holds the spend against the task's cap and spans first to last run", %{proof: proof} do
    assert %Budget{owner: :task} = proof.budget
    assert Decimal.eq?(proof.budget.spent, "0.95")
    assert proof.span == {at(0), at(15)}
  end

  test "an uncapped task without runs has no budget or span" do
    proof = ProofOfWork.new(%{budget_usd: nil, findings: []}, [], [], %Usage{})
    assert %{budget: nil, span: nil, stages: [], reports: []} = proof
    assert proof.findings == [high: 0, medium: 0, low: 0]
  end
end
