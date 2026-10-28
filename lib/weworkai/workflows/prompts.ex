defmodule Weworkai.Workflows.Prompts do
  @moduledoc """
  What each agent run is told, and the JSON schema its result must match
  (docs/workflow.md, "Structured outputs"). Every prompt puts its instructions first and
  the material (task, plan, diff, findings) last, so cutting a prompt down to the bridge's
  limit never cuts an instruction. A block's own instructions (`step`, from the workflow)
  come after the role's and before the material; a resumed conversation gets them first
  (`for_step/2`).
  """
  alias Weworkai.Board.Task

  # bin/claude_bridge's MAX_PROMPT, counted in code points like Python's len/1.
  @max_length 400_000
  @truncated "\n\n[… cut to fit the prompt limit]"

  ## Planner

  def plan(task, step \\ nil) do
    fit("""
    You are the planner. Plan the task below for the repository in your working directory.
    You can only read: writes are blocked, so do not try to change files.

    Read the code you need, then write an implementation plan:
    - `summary`: what will change and why, in markdown.
    - `steps`: small steps in order. Each has an `id` (s1, s2, …), a `title`, a
      `description` (markdown: the why) and `changes`: one unified diff per file of the
      code you intend to write, against the current code.
    - `questions`: decisions a human must make before the work starts, each with an `id`
      (q1, q2, …) and `options` when there are clear choices. Ask instead of guessing.
      Leave it empty when nothing is unclear.

    #{step_section(step)}#{task_section(task)}
    """)
  end

  def revise_plan(body, step_ids) do
    fit("""
    Revise the plan. Return the full revised plan in the same structure, not only the changes.

    Comments: #{step_refs(step_ids)} #{body}
    """)
  end

  ## Coder

  def code(task, step \\ nil) do
    fit("""
    You are the coder. Implement the approved plan below in your working directory, a git
    worktree on branch `#{task.worktree_branch}`. Work only inside it.

    - Follow the plan. If it turns out wrong, or you need a decision it does not cover,
      stop and finish with status `blocked` and your `questions` instead of guessing.
    - Run the relevant tests and make them pass.
    - Commit your work on branch `#{task.worktree_branch}` with clear messages. Never push.
    - When the scope is large, split the work and hand parts to subagents (Task tool).

    Finish with `status` (`done` or `blocked`), a markdown `summary` of what you did, and
    `questions` (empty when done).

    #{step_section(step)}#{task_section(task)}

    # Approved plan

    #{render_plan(task.plan)}
    """)
  end

  def fix(findings, round, max_rounds) do
    fit("""
    The reviewers found the problems below in your work (fix round #{round} of #{max_rounds}).
    Fix every real one, run the tests and commit on the same branch. If a finding is wrong,
    leave it and say why in your summary. Then finish with the same structured result as before.

    #{render_findings(findings)}
    """)
  end

  ## Merger

  @doc """
  Merges the task's worktree branch into `branch` (nil: the branch checked out in the
  repository). The run's folder is the repository, which holds the worktree too.
  """
  def merge(task, branch, step \\ nil) do
    target =
      if branch,
        do: "`#{branch}`",
        else: "the branch checked out in the repository (`git branch --show-current`)"

    fit("""
    You are the merger. Merge the task's branch `#{task.worktree_branch}` (its worktree:
    `#{task.worktree_path}`) into #{target}. Your working directory is the repository
    `#{task.repository}`; its git directory and every worktree in it are writable.

    1. In the task's worktree, commit any uncommitted work on `#{task.worktree_branch}`
       (leave `.weworkai/` out).
    2. Find where the target branch is checked out (`git worktree list`):
       - in the repository or another worktree: merge there, but only if it has no
         uncommitted changes (ignoring `.weworkai/`); otherwise change nothing and finish
         `blocked`;
       - nowhere: add a temporary worktree for it under `.weworkai/merge/`, merge there,
         and remove that worktree before you finish, also when you stop;
       - a branch that doesn't exist: finish `blocked`. Never create it.
    3. `git merge --no-ff #{task.worktree_branch}`. Resolve every conflict by keeping the
       intent of both sides: read the plan below and both branches' history (`git log`).
       Run the tests that cover what conflicted and fix what the merge broke.
    4. Commit the merge. Never rebase, never force, never push to a remote, and change no
       branch but the target. A target that already contains the branch is merged as it is.
    5. If a conflict needs a decision the code and the plan don't settle, run
       `git merge --abort` so the target is left as it was, and finish `blocked`.

    Finish with `status` (`merged` or `blocked`), a markdown `summary` (what was merged,
    each conflict and how you resolved it, or why you stopped and what a human must do),
    `branch` (the target branch's name) and `commit` (the merge commit's hash; empty when
    blocked).

    #{step_section(step)}#{task_section(task)}

    # Approved plan

    #{render_plan(task.plan)}
    """)
  end

  ## Planner or coder, continued by a human (after a failure, or when it seemed stuck)

  def carry_on do
    fit("""
    A human asked you to carry on with the work of this conversation: an earlier run may
    have stopped before it finished. Check where the work stands, continue it, and finish
    with the same structured result as before.
    """)
  end

  ## Planner or coder, entered again by an arrow from another block (or a self-loop)

  def again(block) do
    fit("""
    The workflow sent the task to you again, now as the step “#{block}”. Check where the
    work stands, do what is still to do, and finish with the same structured result as
    before.
    """)
  end

  ## Planner or coder, sent back by a human's decision (an arrow out of a human block)

  def decision(label, comment, findings) do
    open =
      if findings == [], do: "", else: "# Open review findings\n\n#{render_findings(findings)}"

    fit("""
    A human looked at the work so far and decided: “#{label}”. Check where the work
    stands, carry on with it in that light, and finish with the same structured result as
    before.

    #{comment_note(comment)}

    #{open}
    """)
  end

  @doc """
  An agent starting afresh after a human's decision sent the task to it: the decision and
  its comment come first, so cutting the prompt to the limit keeps them.
  """
  def decided(prompt, label, comment) do
    fit("""
    A human decided: “#{label}”, which sent the task to you. Do your part in that light.

    #{comment_note(comment)}

    #{prompt}
    """)
  end

  defp comment_note(nil), do: ""
  defp comment_note(comment), do: "# Their comment\n\n#{comment}"

  ## Planner or coder, after a human answered their questions

  def answers(:planning, questions, answers) do
    fit("""
    A human answered your questions. Revise the plan with these decisions and return the
    full plan in the same structure.

    #{answered(questions, answers)}
    """)
  end

  def answers(:coding, questions, answers) do
    fit("""
    A human answered your questions. Continue the implementation with these decisions,
    commit, and finish with the same structured result as before.

    #{answered(questions, answers)}
    """)
  end

  @doc "The questions with the human's answers, as markdown."
  def answered(questions, answers) do
    Enum.map_join(questions, "\n", fn question ->
      "- **#{question.id}** #{question.question}\n  → #{Map.fetch!(answers, question.id)}"
    end)
  end

  ## Reviewers

  def review(task, diff, step \\ nil) do
    fit("""
    You are the code reviewer. Review the change in your working directory, a git worktree
    on branch `#{task.worktree_branch}`, against the plan it implements. You can only read.

    Report real problems only: bugs, plan steps that are missing or done wrong, security
    issues, broken or missing tests, code that will not build. For each finding give a
    `severity` (high, medium or low), a `title`, the `path` and `line`, and `details`
    (markdown). Never invent a finding; return an empty `findings` list when the change is good.
    The diff below may be cut off; use `git diff` and `git log` in the worktree for the rest.

    #{step_section(step)}#{task_section(task)}

    # Plan

    #{render_plan(task.plan)}

    # Diff

    ```diff
    #{diff}
    ```
    """)
  end

  def qa(task, step \\ nil) do
    prefix = "cph-qa-#{Weworkai.Workflows.Engine.short_id(task)}"

    fit("""
    You are the docker reviewer. Test the change in your working directory, a git worktree
    on branch `#{task.worktree_branch}`, by building and running it, not by reading it.

    1. Build and run it in your own throwaway Docker container. Use the repository's
       Dockerfile or compose file if it has one, otherwise a fitting generic image. Prefix
       every container, network and volume you create with `#{prefix}` (for compose: `-p #{prefix}`)
       and touch nothing else. `docker` talks to a daemon of your own; ports you publish
       are on `localhost`.
    2. A web app or browser extension: install Chrome or Chromium in that container and
       drive it with Playwright. Anything else: the best-fitting approach, such as running
       the CLI, calling the API, running the test suite or fuzzing inputs.
    3. Aim for at least 5 real bugs. Reproduce every one: give `reproduction` steps and
       `evidence` (command output or a screenshot path). If you find fewer within your
       budget, report the real number. Never invent or inflate a bug.
    4. Tear down everything you created (`docker rm -f`, `docker compose -p #{prefix} down -v`)
       before you finish, also when something failed.

    Finish with a markdown `summary` and the `findings`, each with a `severity` (high, medium
    or low), a `title`, `details`, `reproduction` and `evidence`.

    #{step_section(step)}#{task_section(task)}

    # Plan

    #{render_plan(task.plan)}
    """)
  end

  ## A human's question about the task, answered beside the workflow

  @ask """
  A human asks you a question about this task. Answer it in markdown: directly, briefly,
  pointing at files and lines where that helps. Read whatever code you need, but you can
  only read: change nothing, and do not carry on with the task's work. This is a side
  conversation; nothing you write here is applied to the task.
  """

  @doc "For a run that continues a copy of the task's conversation, which knows the task."
  def ask(question), do: fit("#{@ask}\n# Question\n\n#{question}")

  @doc "For a task without a conversation yet: the task's material comes along."
  def ask(task, question) do
    fit("""
    #{@ask}
    # Question

    #{question}

    #{task_section(task)}

    #{material(task)}
    """)
  end

  defp material(task) do
    [
      task.plan && "# Plan\n\n#{render_plan(task.plan)}",
      task.outcome_summary && "# The coder's last summary\n\n#{task.outcome_summary}",
      task.findings != [] && "# Open review findings\n\n#{render_findings(task.findings)}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n\n")
  end

  ## Any other role: the task as written

  def task(task, step \\ nil),
    do:
      fit("#{step_section(step)}#{task.title}\n\n#{task.description}#{attachments_section(task)}")

  @doc "`prompt`, then `more` (a fresh conversation told what a resumed one would be)."
  def followed_by(prompt, more), do: fit("#{prompt}\n\n#{more}")

  ## A block's own instructions

  @doc "A resumed conversation's prompt, with the block's own instructions first."
  def for_step(prompt, nil), do: prompt
  def for_step(prompt, step), do: fit("#{step_section(step)}#{prompt}")

  defp step_section(nil), do: ""
  defp step_section(step), do: "# Instructions for this step (from the workflow)\n\n#{step}\n\n"

  ## Structured output schemas

  @question %{
    "type" => "object",
    "required" => ["id", "question", "options"],
    "properties" => %{
      "id" => %{"type" => "string"},
      "question" => %{"type" => "string"},
      "options" => %{"type" => "array", "items" => %{"type" => "string"}}
    }
  }

  @plan %{
    "type" => "object",
    "required" => ["summary", "steps", "questions"],
    "properties" => %{
      "summary" => %{"type" => "string"},
      "steps" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["id", "title", "description", "changes"],
          "properties" => %{
            "id" => %{"type" => "string"},
            "title" => %{"type" => "string"},
            "description" => %{"type" => "string"},
            "changes" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "required" => ["path", "diff"],
                "properties" => %{
                  "path" => %{"type" => "string"},
                  "diff" => %{"type" => "string"}
                }
              }
            }
          }
        }
      },
      "questions" => %{"type" => "array", "items" => @question}
    }
  }

  @outcome %{
    "type" => "object",
    "required" => ["status", "summary", "questions"],
    "properties" => %{
      "status" => %{"type" => "string", "enum" => ["done", "blocked"]},
      "summary" => %{"type" => "string"},
      "questions" => %{"type" => "array", "items" => @question}
    }
  }

  @findings %{
    "type" => "object",
    "required" => ["summary", "findings"],
    "properties" => %{
      "summary" => %{"type" => "string"},
      "findings" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["id", "severity", "title", "details"],
          "properties" => %{
            "id" => %{"type" => "string"},
            "severity" => %{"type" => "string", "enum" => ["high", "medium", "low"]},
            "title" => %{"type" => "string"},
            "path" => %{"type" => "string"},
            "line" => %{"type" => "integer"},
            "details" => %{"type" => "string"},
            "reproduction" => %{"type" => "string"},
            "evidence" => %{"type" => "string"}
          }
        }
      }
    }
  }

  @merge %{
    "type" => "object",
    "required" => ["status", "summary", "branch", "commit"],
    "properties" => %{
      "status" => %{"type" => "string", "enum" => ["merged", "blocked"]},
      "summary" => %{"type" => "string"},
      "branch" => %{"type" => "string"},
      "commit" => %{"type" => "string"}
    }
  }

  def schema(:planning), do: @plan
  def schema(:coding), do: @outcome
  def schema(stage) when stage in [:code_review, :qa], do: @findings
  def schema(:merging), do: @merge
  def schema(nil), do: nil

  ## Rendering

  @doc "The plan as markdown, each step with its diffs."
  def render_plan(nil), do: "(no plan)"

  def render_plan(plan) do
    steps =
      Enum.map_join(plan.steps, "\n\n", fn step ->
        changes =
          Enum.map_join(step.changes, "\n\n", &"`#{&1.path}`\n\n```diff\n#{&1.diff}\n```")

        "## #{step.id}. #{step.title}\n\n#{step.description}\n\n#{changes}"
      end)

    "#{plan.summary}\n\n#{steps}"
  end

  @doc "Findings as markdown."
  def render_findings(findings) do
    Enum.map_join(findings, "\n\n", fn finding ->
      location = if finding.path, do: " (`#{finding.path}#{line(finding.line)}`)", else: ""

      """
      ### [#{finding.source}] #{finding.id}: #{finding.title} — #{finding.severity}#{location}

      #{finding.details}
      #{field("Reproduction", finding.reproduction)}#{field("Evidence", finding.evidence)}
      """
    end)
  end

  defp line(nil), do: ""
  defp line(line), do: ":#{line}"

  defp field(_label, nil), do: ""
  defp field(label, text), do: "\n**#{label}:** #{text}\n"

  defp step_refs([]), do: "[plan]"
  defp step_refs(step_ids), do: Enum.map_join(step_ids, " ", &"[step #{&1}]")

  defp task_section(%Task{} = task),
    do: "# Task: #{task.title}\n\n#{task.description}#{attachments_section(task)}"

  # Needs `attachment_names` loaded; the files themselves reach the run beside the prompt.
  defp attachments_section(%{attachment_names: []}), do: ""

  defp attachments_section(task) do
    folder = Weworkai.Workflows.Engine.attachments_folder(task)
    files = Enum.map_join(task.attachment_names, "\n", &"- `#{folder}/#{&1}`")

    "\n\n## Attached files\n\nThe human attached these files for you; they are in your " <>
      "working directory. Read the ones the task needs.\n\n#{files}"
  end

  defp fit(prompt) do
    codepoints = String.codepoints(prompt)

    if length(codepoints) <= @max_length do
      prompt
    else
      kept = Enum.take(codepoints, @max_length - String.length(@truncated))
      Enum.join(kept) <> @truncated
    end
  end
end
