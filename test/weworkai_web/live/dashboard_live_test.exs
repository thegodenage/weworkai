defmodule WeworkaiWeb.DashboardLiveTest do
  use WeworkaiWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Weworkai.{Agents, Connectors, Organization}
  alias Weworkai.Agents.SessionPoller
  alias Weworkai.Connectors.ClaudeBridge

  # LiveViews poll the bridge from their own processes.
  setup :set_req_test_to_shared

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  defp agent(name, role, attrs \\ %{model: "claude-opus-5-5", effort: "high"}) do
    connector = Connectors.create_connector!(%{name: "Claude", provider: :claude_code})

    employee =
      Organization.create_employee!(%{
        kind: :agent,
        name: name,
        agent_role: role,
        connector_id: connector.id
      })

    # Skips :configure, whose check would ask the bridge for its model list.
    employee.agent_id
    |> Agents.get_agent!()
    |> Ash.Changeset.for_update(:assign_role, %{role: role})
    |> Ash.Changeset.force_change_attributes(attrs)
    |> Ash.update!()

    employee
  end

  @conversation "0b5e7f0e-3c1a-4d2b-9f6e-2a7c8d9e1f00"

  # Plays the bridge: one run "abcd1234" (running unless :status says otherwise), and
  # reports each request to the test.
  defp stub_bridge(opts \\ []) do
    test = self()
    status = Keyword.get(opts, :status, "running")
    sessions = Keyword.get(opts, :sessions, [%{"id" => "abcd1234", "status" => status}])

    Req.Test.stub(ClaudeBridge, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:bridge, conn.method, conn.request_path, body != "" && JSON.decode!(body)})

      case {conn.method, conn.request_path} do
        {"POST", "/sessions"} ->
          case Keyword.get(opts, :start_error) do
            nil -> Req.Test.json(conn, %{"id" => "abcd1234", "claudeSessionId" => @conversation})
            error -> conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => error})
          end

        {"GET", "/sessions"} ->
          Req.Test.json(conn, %{"sessions" => sessions})

        {"GET", "/sessions/abcd1234"} when sessions == [] ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "session not found"})

        {"GET", "/sessions/abcd1234"} ->
          Req.Test.json(conn, %{
            "id" => "abcd1234",
            "status" => status,
            "output" => "→ Read: mix.exs\nHi",
            "result" => if(status == "done", do: "Hi"),
            "structured" => if(status == "done", do: %{"answer" => "Hi"}),
            "claudeSessionId" => @conversation
          })

        {"POST", "/sessions/abcd1234/stop"} ->
          Req.Test.json(conn, %{"id" => "abcd1234"})
      end
    end)
  end

  # Once the poller answers a call, its poll has run and the result is in the view's mailbox.
  defp await_poll(view) do
    _ = :sys.get_state(SessionPoller)
    render(view)
  end

  defp start_run(employee) do
    Agents.start_run!(%{agent_id: employee.agent_id, folder: "~/Projects/app", task: "Plan auth"})
  end

  test "starting a planner sends its model, effort, read-only profile and prompt", %{conn: conn} do
    employee = agent("Planner", :planner)
    stub_bridge()
    {:ok, view, _html} = live(conn, ~p"/dashboard/new")

    assert has_element?(view, "#run-form option", "Planner · Planner · claude-opus-5-5")

    view
    |> form("#run-form",
      form: %{agent_id: employee.agent_id, folder: "~/Projects/app", task: "Plan auth"}
    )
    |> render_submit()

    assert_receive {:bridge, "POST", "/sessions", spec}

    assert %{
             "cwd" => "~/Projects/app",
             "model" => "claude-opus-5-5",
             "effort" => "high",
             "profile" => "planner",
             "prompt" => "Plan auth",
             "name" => "cph-" <> _,
             "jsonSchema" => nil,
             "resume" => nil
           } = spec

    assert spec["systemPrompt"] =~ "Always write the code changes in the plan"

    [run] = Agents.active_runs!()
    assert run.session_id == "abcd1234"
    assert run.claude_session_id == @conversation
    assert_redirect(view, ~p"/dashboard/runs/#{run.id}")
  end

  test "each role runs with its own profile" do
    stub_bridge()

    for role <- [:coder, :reviewer, :qa, :custom] do
      start_run(agent("#{role}", role, %{model: "sonnet"}))
      expected = Atom.to_string(role)
      assert_receive {:bridge, "POST", "/sessions", %{"profile" => ^expected} = spec}
      refute spec["effort"]
    end
  end

  test "a run can ask for structured output and resume a conversation" do
    employee = agent("Coder", :coder)
    stub_bridge()
    schema = %{"type" => "object", "properties" => %{"status" => %{"type" => "string"}}}

    Agents.start_run!(%{
      agent_id: employee.agent_id,
      folder: "~/Projects/app",
      task: "Fix the review findings",
      json_schema: schema,
      resume: @conversation
    })

    assert_receive {:bridge, "POST", "/sessions",
                    %{"jsonSchema" => ^schema, "resume" => @conversation}}
  end

  test "resume must be a conversation id" do
    employee = agent("Coder", :coder)

    assert {:error, %Ash.Error.Invalid{}} =
             Agents.start_run(%{
               agent_id: employee.agent_id,
               folder: "~/Projects/app",
               task: "x",
               resume: "--dangerously-skip-permissions"
             })
  end

  test "a refused start shows the provider's reason and saves nothing", %{conn: conn} do
    employee = agent("Coder", :coder)
    stub_bridge(start_error: "Workspace not trusted. Run `claude` in ~/Projects/app once.")
    {:ok, view, _html} = live(conn, ~p"/dashboard/new")

    html =
      view
      |> form("#run-form",
        form: %{agent_id: employee.agent_id, folder: "~/Projects/app", task: "x"}
      )
      |> render_submit()

    assert html =~ "Workspace not trusted"
    assert Agents.active_runs!() == []
  end

  test "agents without a model are not offered", %{conn: conn} do
    agent("Idle", :coder, %{model: nil})
    {:ok, view, _html} = live(conn, ~p"/dashboard/new")

    assert render(view) =~ "No agent is ready"
  end

  test "cards show live status and open the run log", %{conn: conn} do
    stub_bridge()
    run = start_run(agent("Coder", :coder))
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    await_poll(view)
    assert has_element?(view, "#run-#{run.id}", "Working")
    assert has_element?(view, "#run-#{run.id}", "Plan auth")

    {:ok, run_view, _html} =
      view |> element("#run-#{run.id}") |> render_click() |> follow_redirect(conn)

    await_poll(run_view)
    assert_push_event(run_view, "terminal:output", %{output: "→ Read: mix.exs\nHi"})
    assert has_element?(run_view, "span", "Working")
    assert has_element?(run_view, "code", @conversation)
  end

  test "a finished run shows done and can be dismissed", %{conn: conn} do
    stub_bridge(status: "done")
    run = start_run(agent("Coder", :coder))
    {:ok, view, _html} = live(conn, ~p"/dashboard/runs/#{run.id}")

    await_poll(view)
    assert has_element?(view, "span", "Done")
    refute has_element?(view, "#stop-run")

    view |> element("#dismiss-run") |> render_click()
    assert_redirect(view, ~p"/dashboard")
    assert Agents.active_runs!() == []
  end

  test "a failed run shows as failed", %{conn: conn} do
    stub_bridge(status: "failed")
    run = start_run(agent("Coder", :coder))
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    await_poll(view)
    assert has_element?(view, "#run-#{run.id}", "Failed")
    assert has_element?(view, "#tally-failed dd", "01")
    assert has_element?(view, "#tally-working dd", "00")
  end

  test "the tallies count runs by status", %{conn: conn} do
    stub_bridge()
    start_run(agent("Coder", :coder))
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    await_poll(view)
    assert has_element?(view, "#tally-active dd", "01")
    assert has_element?(view, "#tally-working dd", "01")
    assert has_element?(view, "#tally-done dd", "00")
  end

  test "a run the bridge no longer knows shows as gone", %{conn: conn} do
    stub_bridge(sessions: [])
    run = start_run(agent("Coder", :coder))
    {:ok, view, _html} = live(conn, ~p"/dashboard/runs/#{run.id}")

    await_poll(view)
    assert has_element?(view, "span", "Gone")
    refute has_element?(view, "#stop-run")
  end

  test "stop ends the run and removes the card", %{conn: conn} do
    stub_bridge()
    run = start_run(agent("Coder", :coder))
    {:ok, view, _html} = live(conn, ~p"/dashboard/runs/#{run.id}")

    view |> element("#stop-run") |> render_click()

    assert_receive {:bridge, "POST", "/sessions/abcd1234/stop", _}
    assert_redirect(view, ~p"/dashboard")
    assert Agents.active_runs!() == []
  end

  test "open tabs share one bridge poll", %{conn: conn} do
    stub_bridge()
    run = start_run(agent("Coder", :coder))
    {:ok, first, _html} = live(conn, ~p"/dashboard")
    {:ok, second, _html} = live(conn, ~p"/dashboard")
    await_poll(first)
    assert_receive {:bridge, "GET", "/sessions", _}
    assert_receive {:bridge, "GET", "/sessions", _}

    send(SessionPoller, :tick)

    assert await_poll(first) =~ "Working"
    assert has_element?(second, "#run-#{run.id}", "Working")
    assert_receive {:bridge, "GET", "/sessions", _}
    refute_received {:bridge, "GET", "/sessions", _}
  end
end
