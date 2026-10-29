defmodule Weworkai.Connectors.Adapters.ClaudeCodeTest do
  use ExUnit.Case, async: true

  alias Weworkai.Connectors.Adapters.ClaudeCode
  alias Weworkai.Connectors.ClaudeBridge

  defp stub_bridge(routes) do
    test = self()

    Req.Test.stub(ClaudeBridge, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:bridge, conn.method, conn.request_path, body != "" && JSON.decode!(body)})
      {status, response} = Map.fetch!(routes, {conn.method, conn.request_path})
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(response)
    end)
  end

  test "a finished run returns its result and structured output" do
    stub_bridge(%{
      {"GET", "/sessions/abcd1234"} =>
        {200,
         %{
           "id" => "abcd1234",
           "status" => "done",
           "output" => "── finished",
           "result" => "{\"answer\":\"init\"}",
           "structured" => %{"answer" => "init"},
           "claudeSessionId" => "0b5e7f0e-3c1a-4d2b-9f6e-2a7c8d9e1f00",
           "costUsd" => 0.01,
           "usage" => %{
             "inputTokens" => 12,
             "outputTokens" => 340,
             "cacheReadTokens" => 5_600,
             "cacheCreationTokens" => 780,
             "costUsd" => 0.01,
             "durationMs" => 4_200,
             "turns" => 3
           }
         }}
    })

    assert {:ok,
            %{
              status: :done,
              structured: %{"answer" => "init"},
              result: "{\"answer\":\"init\"}",
              claude_session_id: "0b5e7f0e-3c1a-4d2b-9f6e-2a7c8d9e1f00",
              usage: %{
                input_tokens: 12,
                output_tokens: 340,
                cache_read_tokens: 5_600,
                cache_creation_tokens: 780,
                cost_usd: 0.01,
                duration_ms: 4_200,
                turns: 3
              }
            }} = ClaudeCode.session("abcd1234")
  end

  test "a run still working, or on an older bridge, reports no usage" do
    stub_bridge(%{
      {"GET", "/sessions/abcd1234"} =>
        {200,
         %{
           "id" => "abcd1234",
           "status" => "running",
           "output" => "",
           "result" => nil,
           "structured" => nil,
           "claudeSessionId" => "0b5e7f0e-3c1a-4d2b-9f6e-2a7c8d9e1f00"
         }}
    })

    assert {:ok, %{status: :working, usage: nil}} = ClaudeCode.session("abcd1234")
  end

  test "run statuses keep done, failed and stopped apart" do
    stub_bridge(%{
      {"GET", "/sessions"} =>
        {200,
         %{
           "sessions" =>
             for {id, status} <- [a: "running", b: "done", c: "failed", d: "stopped"] do
               %{"id" => Atom.to_string(id), "status" => status}
             end
         }}
    })

    assert {:ok, sessions} = ClaudeCode.list_sessions()

    assert Enum.map(sessions, & &1.status) == [:working, :done, :failed, :stopped]
  end

  test "creates a worktree and reads its diff" do
    stub_bridge(%{
      {"POST", "/worktrees"} =>
        {200,
         %{
           "path" => "/Users/me/Projects/app/.weworkai/worktrees/t1",
           "branch" => "weworkai/t1",
           "base" => "abc123"
         }},
      {"POST", "/worktrees/diff"} => {200, %{"diff" => "+hello", "truncated" => false}}
    })

    assert {:ok, %{path: path, branch: "weworkai/t1", base: "abc123"}} =
             ClaudeCode.create_worktree("~/Projects/app", "t1")

    assert_received {:bridge, "POST", "/worktrees", %{"repo" => "~/Projects/app", "name" => "t1"}}

    assert {:ok, "+hello"} = ClaudeCode.worktree_diff(path)
    assert_received {:bridge, "POST", "/worktrees/diff", %{"path" => ^path}}
  end

  test "a refused worktree returns the bridge's reason" do
    stub_bridge(%{
      {"POST", "/worktrees"} => {422, %{"error" => "/tmp is not the root of a git repository"}}
    })

    assert {:error, "/tmp is not the root of a git repository"} =
             ClaudeCode.create_worktree("/tmp", "t1")
  end

  test "host tools: the bridge's tools, shared agent config and recent calls" do
    stub_bridge(%{
      {"GET", "/tools"} =>
        {200,
         %{
           "hostTools" => [
             %{
               "name" => "glab",
               "description" => "GitLab CLI",
               "installed" => true,
               "loggedIn" => true,
               "account" => "gitlab.com"
             }
           ],
           "claudeHome" => [%{"name" => "skills", "items" => ["release-notes"]}],
           "recent" => [
             %{
               "at" => "2026-10-29T10:00:00+00:00",
               "run" => "0123abcd",
               "name" => "cph-abcdefgh",
               "cwd" => "/Users/me/Projects",
               "tool" => "glab",
               "command" => "glab api /events"
             }
           ]
         }}
    })

    assert {:ok,
            %{
              tools: [%{name: "glab", logged_in: true, account: "gitlab.com"}],
              shared: [%{name: "skills", items: ["release-notes"]}],
              recent: [%{tool: "glab", session_name: "cph-abcdefgh", at: %DateTime{}}]
            }} = ClaudeCode.host_tools()
  end

  test "host tools on a bridge without /tools is an outdated bridge" do
    stub_bridge(%{{"GET", "/tools"} => {404, %{"error" => "not found"}}})
    assert {:error, "Claude bridge is outdated" <> _} = ClaudeCode.host_tools()
  end

  test "a run reports the tools it could use and used" do
    stub_bridge(%{
      {"GET", "/sessions/abcd1234"} =>
        {200,
         %{
           "id" => "abcd1234",
           "status" => "running",
           "output" => "",
           "claudeSessionId" => "0b5e7f0e-3c1a-4d2b-9f6e-2a7c8d9e1f00",
           "tools" => %{
             "available" => %{
               "tools" => ["Bash"],
               "skills" => ["release-notes"],
               "hostTools" => ["glab"],
               "sharedClaude" => ["skills"]
             },
             "calls" => %{"Bash" => 2},
             "skills" => [],
             "hostCalls" => [%{"tool" => "glab", "command" => "glab mr list"}]
           }
         }}
    })

    assert {:ok,
            %{
              tools: %{
                host_tools: ["glab"],
                calls: %{"Bash" => 2},
                host_calls: [%{tool: "glab", command: "glab mr list"}]
              }
            }} = ClaudeCode.session("abcd1234")
  end

  test "a worktree across a folder of repositories names them" do
    stub_bridge(%{
      {"POST", "/worktrees"} =>
        {200,
         %{
           "path" => "/p/.weworkai/worktrees/abcd1234",
           "branch" => "weworkai/abcd1234",
           "base" => nil,
           "repositories" => ["api", "web"]
         }}
    })

    assert {:ok, %{repositories: ["api", "web"], base: nil}} =
             ClaudeCode.create_worktree("/p", "abcd1234")
  end
end
