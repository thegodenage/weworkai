defmodule Weworkai.Board.ProofOfWork do
  @moduledoc """
  What a human weighs at the review gate, in one value: the open findings per severity,
  each agent's latest report (a reviewer's with the findings it still has open), the runs
  per stage with their time and cost, the task's spend against its budget, and the span
  from the first run to the last. The branch's diff stats come apart (`diff_files/1`),
  since they are read from the bridge.
  """
  alias Weworkai.{Connectors, Diff}
  alias Weworkai.Agents.{Budget, Usage}

  @enforce_keys [:findings, :reports, :stages, :usage, :budget, :span]
  defstruct [:findings, :reports, :stages, :usage, :budget, :span]

  @type report :: %{
          role: atom(),
          body: String.t(),
          at: DateTime.t(),
          open: non_neg_integer() | nil
        }
  @type stage :: %{
          stage: atom() | nil,
          runs: pos_integer(),
          failed: non_neg_integer(),
          duration_ms: non_neg_integer(),
          cost_usd: Decimal.t(),
          state: atom(),
          last_run_id: String.t()
        }
  @type t :: %__MODULE__{
          findings: [{:high | :medium | :low, non_neg_integer()}],
          reports: [report()],
          stages: [stage()],
          usage: Usage.t(),
          budget: Budget.t() | nil,
          span: {DateTime.t(), DateTime.t()} | nil
        }

  @severities [:high, :medium, :low]
  @report_kinds [:outcome, :findings]
  @reviewer_roles [:reviewer, :qa]

  @doc """
  The bundle for `task` from its messages (oldest first), its run attempts (newest first,
  as `Scheduling.task_runs!/1` reads them, `agent_run.usage` loaded) and its usage total.
  """
  @spec new(Ash.Resource.record(), [Ash.Resource.record()], [Ash.Resource.record()], Usage.t()) ::
          t()
  def new(task, messages, attempts, usage) do
    chronological = Enum.reverse(attempts)

    %__MODULE__{
      findings:
        Enum.map(
          @severities,
          &{&1, Enum.count(task.findings, fn found -> found.severity == &1 end)}
        ),
      reports: reports(messages, task.findings),
      stages: stages(chronological),
      usage: usage,
      budget:
        task.budget_usd && %Budget{owner: :task, cap: task.budget_usd, spent: usage.cost_usd},
      span: span(chronological)
    }
  end

  # The latest report per agent role, in the order the roles first reported.
  defp reports(messages, findings) do
    messages
    |> Enum.filter(&(&1.author == :agent and &1.kind in @report_kinds))
    |> Enum.group_by(& &1.agent_role)
    |> Enum.map(fn {role, [first | _] = reported} ->
      latest = List.last(reported)

      {first.inserted_at,
       %{role: role, body: latest.body, at: latest.inserted_at, open: open(role, findings)}}
    end)
    |> Enum.sort_by(&elem(&1, 0), DateTime)
    |> Enum.map(&elem(&1, 1))
  end

  defp open(role, findings) when role in @reviewer_roles,
    do: Enum.count(findings, &(&1.source == role))

  defp open(_role, _findings), do: nil

  defp stages(attempts) do
    attempts
    |> Enum.group_by(& &1.job.stage)
    |> Enum.sort_by(fn {_stage, [first | _]} -> first.inserted_at end, DateTime)
    |> Enum.map(fn {stage, runs} -> stage(stage, runs) end)
  end

  defp stage(stage, runs) do
    usages = runs |> Enum.map(& &1.agent_run.usage) |> Enum.reject(&is_nil/1)
    total = Usage.total(usages)
    latest = List.last(runs)

    %{
      stage: stage,
      runs: length(runs),
      failed: Enum.count(runs, &(&1.state == :failed)),
      duration_ms: total.duration_ms,
      cost_usd: total.cost_usd,
      state: latest.state,
      last_run_id: latest.agent_run_id
    }
  end

  defp span([]), do: nil
  defp span([first | _] = attempts), do: {first.inserted_at, List.last(attempts).updated_at}

  @doc """
  The branch's changes per file, read from the bridge the coder ran on, as
  `{path, %Diff{}}`; an error when the task has no coder conversation to read it from.
  """
  @spec diff_files(Ash.Resource.record()) ::
          {:ok, [{String.t(), Diff.t()}]} | {:error, String.t()}
  def diff_files(%{code_session_connector_id: nil}),
    do: {:error, "No coder ran on a known connector, so the branch can't be read."}

  def diff_files(task) do
    connector = Connectors.get_connector!(task.code_session_connector_id)

    with {:ok, diff} <- Connectors.worktree_diff(connector, task.worktree_path),
         do: {:ok, Diff.files(diff)}
  end
end
