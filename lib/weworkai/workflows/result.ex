defmodule Weworkai.Workflows.Result do
  @moduledoc """
  Turns a finished run's output into what its stage expects, or the reason it can't. The
  agent's structured output is checked once, here, so the workflow can trust it.
  """
  alias Weworkai.Board.{Finding, Plan, Question}

  @type t ::
          String.t()
          | Plan.t()
          | %{status: :done | :blocked, summary: String.t(), questions: [Question.t()]}
          | %{summary: String.t(), findings: [Finding.t()]}
          | %{
              status: :merged | :blocked,
              summary: String.t(),
              branch: String.t(),
              commit: String.t()
            }

  @spec parse(atom() | nil, map()) :: {:ok, t()} | {:error, String.t()}
  def parse(nil, session), do: {:ok, session.result || "The agent finished without a summary."}

  def parse(:ask, %{result: nil}), do: {:error, "The agent finished without an answer."}
  def parse(:ask, %{result: answer}), do: {:ok, answer}

  def parse(_stage, %{structured: nil}) do
    {:error, "The agent finished without a structured result."}
  end

  def parse(:planning, %{structured: structured}), do: cast(Plan, structured, "plan")

  def parse(:coding, %{structured: %{"status" => status, "summary" => summary} = structured})
      when status in ["done", "blocked"] do
    with {:ok, questions} <-
           cast({:array, Question}, Map.get(structured, "questions", []), "outcome") do
      {:ok, %{status: String.to_existing_atom(status), summary: summary, questions: questions}}
    end
  end

  def parse(:coding, _session), do: mismatch("outcome")

  def parse(
        :merging,
        %{
          structured: %{"status" => status, "summary" => summary, "branch" => branch} = structured
        }
      )
      when status in ["merged", "blocked"] and is_binary(summary) and is_binary(branch) do
    {:ok,
     %{
       status: String.to_existing_atom(status),
       summary: summary,
       branch: branch,
       commit: Map.get(structured, "commit") || ""
     }}
  end

  def parse(:merging, _session), do: mismatch("merge")

  def parse(stage, %{structured: %{"summary" => summary, "findings" => findings}})
      when stage in [:code_review, :qa] and is_list(findings) do
    source = if stage == :code_review, do: "reviewer", else: "qa"

    with {:ok, findings} <-
           cast({:array, Finding}, Enum.map(findings, &Map.put(&1, "source", source)), "findings") do
      {:ok, %{summary: summary, findings: findings}}
    end
  end

  def parse(_review_stage, _session), do: mismatch("findings")

  defp cast(type, value, schema) do
    case Ash.Type.cast_input(type, value, []) do
      {:ok, cast} when not is_nil(cast) -> {:ok, cast}
      _invalid -> mismatch(schema)
    end
  end

  defp mismatch(schema), do: {:error, "The agent's result did not match the #{schema} schema."}
end
