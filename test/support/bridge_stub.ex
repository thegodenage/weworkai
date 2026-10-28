defmodule Weworkai.BridgeStub do
  @moduledoc """
  Plays bin/claude_bridge through `Req.Test`, with state: runs finish as soon as the test
  syncs, each with the next result queued for its profile (or a default like
  bin/fake_claude_bridge's). Every request is reported to the test process as
  `{:bridge, method, path, body}`.
  """
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Weworkai.Agents
  alias Weworkai.Connectors.ClaudeBridge
  alias Weworkai.Scheduling.Scheduler

  @diff "--- /dev/null\n+++ b/lib/greeting.ex\n@@ -0,0 +1 @@\n+defmodule Greeting, do: nil\n"

  def diff, do: @diff

  def start do
    state = start_supervised!({Agent, fn -> %{runs: %{}, queued: %{}, count: 0} end})
    restore(state)
  end

  @doc "Puts the stub back after a test replaced it for a while."
  def restore(state) do
    test = self()
    Req.Test.stub(ClaudeBridge, &handle(&1, test, state))
    state
  end

  @doc """
  Queues `result` for the next run of `profile`: a structured map, `{:answer, text}` (a
  plain final result, as a question's run ends), `:fail` or `:no_output`.
  """
  def queue(state, profile, result) do
    Agent.update(state, fn state ->
      update_in(
        state.queued,
        &Map.update(&1, profile, [result], fn queued -> queued ++ [result] end)
      )
    end)
  end

  @doc "Starts the due runs, then lets every running one finish and the scheduler see it."
  def step(state) do
    Scheduler.dispatch_due()

    statuses =
      Agent.get(state, fn %{runs: runs} ->
        Map.new(Agents.active_runs!(), &{&1.id, status(runs[&1.session_id])})
      end)

    Scheduler.sync_runs(statuses)
  end

  defp status(%{result: :fail}), do: :failed
  defp status(_run), do: :done

  def plan(questions \\ [question()]) do
    %{
      "summary" => "Add a greeting helper.",
      "steps" => [
        %{
          "id" => "s1",
          "title" => "Add the Greeting module",
          "description" => "Keeps it testable.",
          "changes" => [%{"path" => "lib/greeting.ex", "diff" => @diff}]
        },
        %{"id" => "s2", "title" => "Test it", "description" => "Locks it in.", "changes" => []}
      ],
      "questions" => questions
    }
  end

  def question(id \\ "q1") do
    %{"id" => id, "question" => "Localize the greeting?", "options" => ["No", "Gettext"]}
  end

  def outcome(status \\ "done", questions \\ []) do
    %{"status" => status, "summary" => "Implemented the plan.", "questions" => questions}
  end

  @doc "A merger's result: `merged` into `branch`, or `blocked` on a conflict."
  def merge(status \\ "merged", branch \\ "main") do
    merged? = status == "merged"

    %{
      "status" => status,
      "summary" => if(merged?, do: "Merged cleanly.", else: "A conflict needs a decision."),
      "branch" => branch,
      "commit" => if(merged?, do: String.duplicate("a", 40), else: "")
    }
  end

  def findings(count) do
    %{
      "summary" => "#{count} findings.",
      "findings" =>
        for number <- 1..count//1 do
          %{
            "id" => "f#{number}",
            "severity" => "high",
            "title" => "Crashes on nil #{number}",
            "path" => "lib/greeting.ex",
            "line" => 1,
            "details" => "`hello(nil)` raises."
          }
        end
    }
  end

  # A run without a schema on a read-only profile is a question.
  defp default(profile, %{"jsonSchema" => nil, "prompt" => prompt})
       when profile in ["planner", "reviewer"] do
    [_instructions, question] = String.split(prompt, "# Question\n\n", parts: 2)
    {:answer, "Stub answer to: " <> hd(String.split(question, "\n"))}
  end

  defp default("planner", %{"resume" => nil}), do: plan()
  defp default("planner", _body), do: plan([])
  defp default("coder", _body), do: outcome()
  defp default("merger", _body), do: merge()
  defp default(_reviewer, _body), do: findings(0)

  defp handle(conn, test, state) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    body = if raw == "", do: nil, else: JSON.decode!(raw)
    send(test, {:bridge, conn.method, conn.request_path, body})

    case {conn.method, conn.request_path} do
      {"POST", "/sessions"} ->
        Req.Test.json(conn, start_run(state, body))

      {"GET", "/sessions"} ->
        runs = Agent.get(state, & &1.runs)
        Req.Test.json(conn, %{"sessions" => Enum.map(runs, fn {id, _run} -> %{"id" => id} end)})

      {"GET", "/sessions/" <> id} ->
        Req.Test.json(conn, session(Agent.get(state, &Map.fetch!(&1.runs, id)), id))

      {"POST", "/sessions/" <> _stop} ->
        Req.Test.json(conn, %{})

      {"POST", "/worktrees"} ->
        Req.Test.json(conn, %{
          "path" => "#{body["repo"]}/.weworkai/worktrees/#{body["name"]}",
          "branch" => "weworkai/#{body["name"]}",
          "base" => String.duplicate("0", 40)
        })

      {"POST", "/worktrees/diff"} ->
        Req.Test.json(conn, %{"diff" => @diff, "truncated" => false})

      {"GET", "/folders"} ->
        folders(conn, URI.decode_query(conn.query_string)["path"])
    end
  end

  defp folders(conn, "") do
    Req.Test.json(conn, %{
      "path" => nil,
      "parent" => nil,
      "folders" => [%{"name" => "Projects", "path" => "~/Projects", "git" => false}]
    })
  end

  defp folders(conn, "~/Projects") do
    Req.Test.json(conn, %{
      "path" => "~/Projects",
      "parent" => nil,
      "folders" => [%{"name" => "app", "path" => "~/Projects/app", "git" => true}]
    })
  end

  defp folders(conn, path) do
    conn
    |> Plug.Conn.put_status(422)
    |> Req.Test.json(%{"error" => "#{path} is not a folder on this computer"})
  end

  defp start_run(state, body) do
    Agent.get_and_update(state, fn state ->
      id = String.pad_leading(Integer.to_string(state.count, 16), 8, "0")
      {result, queued} = next_result(state.queued, body)

      conversation =
        if body["fork"], do: Ecto.UUID.generate(), else: body["resume"] || Ecto.UUID.generate()

      run = %{result: result, conversation: conversation}

      {%{"id" => id, "claudeSessionId" => conversation},
       %{state | runs: Map.put(state.runs, id, run), queued: queued, count: state.count + 1}}
    end)
  end

  defp next_result(queued, %{"profile" => profile} = body) do
    case Map.get(queued, profile, []) do
      [result | rest] -> {result, Map.put(queued, profile, rest)}
      [] -> {default(profile, body), queued}
    end
  end

  defp session(%{result: :fail} = run, id), do: finished(run, id, "failed", nil)
  defp session(%{result: :no_output} = run, id), do: finished(run, id, "done", nil)

  defp session(%{result: {:answer, answer}} = run, id),
    do: %{finished(run, id, "done", nil) | "result" => answer}

  defp session(%{result: result} = run, id), do: finished(run, id, "done", result)

  defp finished(run, id, status, structured) do
    %{
      "id" => id,
      "status" => status,
      "output" => "",
      "result" => "Finished.",
      "structured" => structured,
      "claudeSessionId" => run.conversation,
      "usage" => usage()
    }
  end

  @doc "What every finished stub run reports it used."
  def usage do
    %{
      "inputTokens" => 1_000,
      "outputTokens" => 200,
      "cacheReadTokens" => 3_000,
      "cacheCreationTokens" => 400,
      "costUsd" => 0.0525,
      "durationMs" => 1_500,
      "turns" => 3
    }
  end
end
