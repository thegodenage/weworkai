defmodule WeworkaiWeb.EmployeesLiveTest do
  use WeworkaiWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Weworkai.{Agents, Connectors, Organization}

  defp create_connector(name, status \\ :disconnected) do
    connector = Connectors.create_connector!(%{name: name, provider: :claude_code})

    connector
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:status, status)
    |> Ash.update!()
  end

  defp create_agent(name, connector) do
    Organization.create_employee!(%{
      kind: :agent,
      name: name,
      agent_role: :coder,
      connector_id: connector.id
    })
  end

  test "creates a human employee without an agent", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/employees/new")

    view
    |> form("#employee-form", form: %{kind: "human", name: "Ada", role: "Engineer"})
    |> render_submit()

    assert_patch(view, ~p"/employees?page=1")
    assert has_element?(view, "#employees", "Ada")
    assert has_element?(view, "#employees span[title=Ada]", "A")

    assert [%{kind: :human, agent_id: nil}] =
             Organization.list_employees!(page: [limit: 20]).results

    assert Agents.list_agents!() == []
  end

  test "choosing agent reveals a required connector select", %{conn: conn} do
    connector = create_connector("My Claude")
    {:ok, view, _html} = live(conn, ~p"/employees/new")

    refute has_element?(view, "#employee-form select[name='form[connector_id]']")

    view |> form("#employee-form", form: %{kind: "agent"}) |> render_change()
    assert has_element?(view, "#employee-form option", "My Claude (Disconnected)")

    assert view
           |> form("#employee-form", form: %{kind: "agent", name: "Bot", agent_role: "coder"})
           |> render_submit() =~ "must be present"

    view
    |> form("#employee-form",
      form: %{kind: "agent", name: "Bot", agent_role: "coder", connector_id: connector.id}
    )
    |> render_submit()

    assert [%{kind: :agent, agent: agent}] =
             Organization.list_employees!(page: [limit: 20]).results

    assert agent.connector_link.connector_id == connector.id
  end

  test "edit can switch an agent's connector", %{conn: conn} do
    first = create_connector("First")
    second = create_connector("Second")
    employee = create_agent("Bot", first)
    {:ok, view, _html} = live(conn, ~p"/employees/#{employee.id}/edit")

    assert has_element?(view, "#employee-form option[selected][value='#{first.id}']")

    view
    |> form("#employee-form", form: %{connector_id: second.id})
    |> render_submit()

    assert {:ok, %{agent: %{connector_link: link}}} =
             Organization.get_employee(employee.id, load: [agent: :connector_link])

    assert link.connector_id == second.id
  end

  test "agent rows show the connector state", %{conn: conn} do
    create_agent("Live bot", create_connector("Live", :connected))
    inactive = create_connector("Down", :error)
    create_agent("Down bot", inactive)
    removed = create_connector("Gone", :connected)
    create_agent("Orphan bot", removed)
    :ok = Connectors.remove_connector(removed)

    {:ok, view, _html} = live(conn, ~p"/employees")

    assert has_element?(view, "#employees span.tone-green", "Live")
    refute has_element?(view, "#employees a.tone-green")
    assert has_element?(view, "#employees a.tone-red[href='/connectors?selected=#{inactive.id}']")
    assert has_element?(view, "#employees span.tone-red", "Connector removed")
  end

  test "rejects a blank name", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/employees/new")

    assert view
           |> form("#employee-form", form: %{kind: "human", name: "", role: "Engineer"})
           |> render_submit() =~ "is required"
  end

  test "edits name and role but not kind", %{conn: conn} do
    employee = Organization.create_employee!(%{kind: :human, name: "Ada", role: "Engineer"})
    {:ok, view, _html} = live(conn, ~p"/employees/#{employee.id}/edit")

    refute has_element?(view, "#employee-form select[name='form[kind]']")

    view
    |> form("#employee-form", form: %{name: "Ada L.", role: "Lead"})
    |> render_submit()

    assert has_element?(view, "#employees", "Ada L.")
    assert has_element?(view, "#employees", "Lead")
  end

  test "removing an agent employee removes its agent", %{conn: conn} do
    employee = create_agent("Bot", create_connector("Claude"))
    {:ok, view, _html} = live(conn, ~p"/employees")

    view |> element("a[aria-label='Remove Bot']") |> render_click()

    refute has_element?(view, "#employees", "Bot")
    assert {:error, _} = Organization.get_employee(employee.id)
    assert Agents.list_agents!() == []
    assert Ash.read!(Agents.AgentConnector) == []
  end

  test "paginates 20 per page", %{conn: conn} do
    for number <- 1..21 do
      name = "Employee #{String.pad_leading("#{number}", 2, "0")}"
      Organization.create_employee!(%{kind: :human, name: name, role: "Staff"})
    end

    {:ok, view, _html} = live(conn, ~p"/employees")
    assert has_element?(view, "#employees", "Employee 20")
    refute has_element?(view, "#employees", "Employee 21")
    assert render(view) =~ "Page 1 of 2"

    view |> element("a", "Next") |> render_click()

    assert_patch(view, ~p"/employees?page=2")
    assert has_element?(view, "#employees", "Employee 21")
    refute has_element?(view, "#employees", "Employee 01")
  end

  defp stub_models do
    Req.Test.stub(Weworkai.Connectors.ClaudeBridge, fn %{request_path: "/models"} = conn ->
      Req.Test.json(conn, %{
        "version" => "2.1.294 (Claude Code)",
        "models" => [
          %{"id" => "claude-opus-5-5", "label" => "Opus 5.5"},
          %{"id" => "claude-sonnet-5-5", "label" => "Sonnet 5.5"}
        ],
        "efforts" => ["medium", "high"]
      })
    end)
  end

  test "configures an agent's model and effort from the connector's fresh list", %{conn: conn} do
    employee = create_agent("Planner", create_connector("Claude", :connected))
    stub_models()
    {:ok, view, _html} = live(conn, ~p"/employees")
    Req.Test.allow(Weworkai.Connectors.ClaudeBridge, self(), view.pid)

    refute has_element?(view, "#employees", "claude-opus-5-5")
    assert has_element?(view, "#employees", "Not set")

    view |> element("a[aria-label='Configure Planner']") |> render_click()
    assert_patch(view, ~p"/employees/#{employee.id}/agent?page=1")
    render_async(view)

    assert has_element?(view, "#agent-form option", "Opus 5.5")

    view
    |> form("#agent-form", form: %{model: "claude-opus-5-5", effort: "high"})
    |> render_submit()

    assert has_element?(view, "#employees", "claude-opus-5-5 · high")
  end

  test "sets an agent's budget; the list shows it as a meter", %{conn: conn} do
    employee = create_agent("Planner", create_connector("Claude", :connected))
    stub_models()
    {:ok, view, _html} = live(conn, ~p"/employees/#{employee.id}/agent")
    Req.Test.allow(Weworkai.Connectors.ClaudeBridge, self(), view.pid)
    render_async(view)

    view
    |> form("#agent-form",
      form: %{model: "claude-opus-5-5", budget_usd: "5", budget_period: "week"}
    )
    |> render_submit()

    assert has_element?(view, "#budget-#{employee.id}[data-mark=ok]", "$0 / $5.00")
  end

  test "configure explains when the connector cannot list models", %{conn: conn} do
    create_agent("Planner", create_connector("Claude"))

    Req.Test.stub(
      Weworkai.Connectors.ClaudeBridge,
      &Req.Test.transport_error(&1, :econnrefused)
    )

    {:ok, view, _html} = live(conn, ~p"/employees")
    Req.Test.allow(Weworkai.Connectors.ClaudeBridge, self(), view.pid)

    view |> element("a[aria-label='Configure Planner']") |> render_click()

    assert render_async(view) =~ "Claude bridge is not running"
    refute has_element?(view, "#agent-form")
  end

  test "humans have no Configure action", %{conn: conn} do
    Organization.create_employee!(%{kind: :human, name: "Ada", role: "Engineer"})
    {:ok, view, _html} = live(conn, ~p"/employees")

    refute has_element?(view, "a[aria-label='Configure Ada']")
  end

  test "an agent cannot be saved with a model its connector does not offer" do
    employee = create_agent("Planner", create_connector("Claude"))
    stub_models()

    assert {:error, error} =
             Agents.configure_agent(employee.agent_id |> Agents.get_agent!(), %{model: "gpt-9"})

    assert Exception.message(error) =~ "is not offered by Claude"

    assert {:error, error} =
             Agents.configure_agent(Agents.get_agent!(employee.agent_id), %{
               model: "claude-opus-5-5",
               effort: "ludicrous"
             })

    assert Exception.message(error) =~ "effort"

    assert {:ok, %{model: "claude-opus-5-5", effort: nil}} =
             Agents.configure_agent(Agents.get_agent!(employee.agent_id), %{
               model: "claude-opus-5-5"
             })
  end

  test "agents pick a role from the list; humans type one", %{conn: conn} do
    create_connector("Claude")
    {:ok, view, _html} = live(conn, ~p"/employees/new")

    assert has_element?(view, "#employee-form input[name='form[role]']")
    refute has_element?(view, "#employee-form select[name='form[agent_role]']")

    view |> form("#employee-form", form: %{kind: "agent"}) |> render_change()

    refute has_element?(view, "#employee-form input[name='form[role]']")

    for label <- ["Planner", "Coder", "Reviewer", "Docker reviewer", "Custom"] do
      assert has_element?(view, "#employee-form select[name='form[agent_role]'] option", label)
    end
  end

  test "a planner starts with the planner prompt, editable in Configure", %{conn: conn} do
    employee =
      Organization.create_employee!(%{
        kind: :agent,
        name: "Planner",
        agent_role: :planner,
        connector_id: create_connector("Claude", :connected).id
      })

    agent = Agents.get_agent!(employee.agent_id)
    assert agent.prompt =~ "Always write the code changes in the plan"
    assert Agents.Agent.Role.read_only?(agent.role)

    stub_models()
    {:ok, view, _html} = live(conn, ~p"/employees/#{employee.id}/agent")
    Req.Test.allow(Weworkai.Connectors.ClaudeBridge, self(), view.pid)
    render_async(view)

    assert has_element?(view, "#agent-form textarea", "Always write the code changes in the plan")
    assert has_element?(view, "#agent-modal", "Planner agents run in a sandboxed container")

    view
    |> form("#agent-form",
      form: %{model: "claude-opus-5-5", prompt: "Plan only. Use the GitHub CLI."}
    )
    |> render_submit()

    assert Agents.get_agent!(employee.agent_id).prompt == "Plan only. Use the GitHub CLI."
  end

  test "changing role follows the default prompt only while it is untouched" do
    employee = create_agent("Bot", create_connector("Claude"))
    agent = Agents.get_agent!(employee.agent_id)
    assert agent.prompt == nil

    agent = Agents.assign_agent_role!(agent, %{role: :planner})
    assert agent.prompt =~ "Always write the code changes in the plan"

    agent = Agents.assign_agent_role!(agent, %{role: :reviewer})
    assert agent.prompt == nil

    agent =
      agent
      |> Ash.Changeset.for_update(:assign_role, %{role: :reviewer})
      |> Ash.Changeset.force_change_attribute(:prompt, "Mine")
      |> Ash.update!()

    assert Agents.assign_agent_role!(agent, %{role: :planner}).prompt == "Mine"
  end

  test "database rejects an agent employee without an agent" do
    assert_raise Postgrex.Error, ~r/agent_employees_have_agent/, fn ->
      Weworkai.Repo.query!(
        "INSERT INTO employees (id, kind, name) VALUES (gen_random_uuid(), 'agent', 'X')"
      )
    end
  end
end
