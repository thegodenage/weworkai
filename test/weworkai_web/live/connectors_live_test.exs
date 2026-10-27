defmodule WeworkaiWeb.ConnectorsLiveTest do
  use WeworkaiWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Weworkai.Connectors
  alias Weworkai.Connectors.{Auth, ClaudeBridge}

  defp stub_bridge(response) do
    Req.Test.stub(ClaudeBridge, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-bridge-token"]
      response.(conn)
    end)
  end

  defp logged_in(conn) do
    Req.Test.json(conn, %{
      "loggedIn" => true,
      "email" => "me@weworkai.com",
      "subscriptionType" => "max"
    })
  end

  defp live_with_bridge(conn, path) do
    {:ok, view, _html} = live(conn, path)
    Req.Test.allow(ClaudeBridge, self(), view.pid)
    view
  end

  defp create_connector(name),
    do: Connectors.create_connector!(%{name: name, provider: :claude_code})

  test "creates a Claude Code connector", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/connectors/new")

    view
    |> form("#connector-form", form: %{provider: "claude_code", name: "My Claude"})
    |> render_submit()

    assert has_element?(view, "#connectors", "My Claude")
    assert has_element?(view, "#connectors img[src='/images/connectors/claude_code.svg']")
    assert has_element?(view, "#connectors", "Disconnected")
  end

  test "edits the name", %{conn: conn} do
    connector = create_connector("Old name")
    {:ok, view, _html} = live(conn, ~p"/connectors/#{connector.id}/edit")

    refute has_element?(view, "#connector-form select[name='form[provider]']")
    view |> form("#connector-form", form: %{name: "New name"}) |> render_submit()

    assert has_element?(view, "#connectors", "New name")
  end

  test "connecting through the bridge stores auth metadata", %{conn: conn} do
    connector = create_connector("Claude")
    stub_bridge(&logged_in/1)
    view = live_with_bridge(conn, ~p"/connectors")

    view |> element("a[aria-label='Connect Claude']") |> render_click()

    assert has_element?(view, "#connectors", "Connected")
    assert has_element?(view, "#connectors", "me@weworkai.com")
    assert [%{method: :local_session, metadata: %{"email" => "me@weworkai.com"}}] = Ash.read!(Auth)

    # Reconnecting replaces the metadata instead of adding a second row.
    view |> element("a[aria-label='Connect Claude']") |> render_click()
    assert [%{connector_id: connector_id}] = Ash.read!(Auth)
    assert connector_id == connector.id
  end

  test "a logged-out Claude Code marks the connector as errored and drops old auth", %{conn: conn} do
    create_connector("Claude")
    stub_bridge(&logged_in/1)
    view = live_with_bridge(conn, ~p"/connectors")
    view |> element("a[aria-label='Connect Claude']") |> render_click()

    stub_bridge(&Req.Test.json(&1, %{"loggedIn" => false}))
    view |> element("a[aria-label='Connect Claude']") |> render_click()

    assert has_element?(view, "#connectors", "Claude Code is not logged in")
    assert Ash.read!(Auth) == []
  end

  test "an unreachable bridge explains how to start it", %{conn: conn} do
    create_connector("Claude")
    stub_bridge(&Req.Test.transport_error(&1, :econnrefused))
    view = live_with_bridge(conn, ~p"/connectors")

    view |> element("a[aria-label='Connect Claude']") |> render_click()

    assert has_element?(view, "#connectors", "bin/claude_bridge")
  end

  test "removing a connector removes its auth metadata", %{conn: conn} do
    create_connector("Claude")
    stub_bridge(&logged_in/1)
    view = live_with_bridge(conn, ~p"/connectors")
    view |> element("a[aria-label='Connect Claude']") |> render_click()

    view |> element("a[aria-label='Remove Claude']") |> render_click()

    refute has_element?(view, "#connectors", "Claude")
    assert Ash.read!(Auth) == []
  end

  test "?selected opens the page holding the connector and highlights it", %{conn: conn} do
    for number <- 1..21 do
      create_connector("Connector #{String.pad_leading("#{number}", 2, "0")}")
    end

    [target] = Connectors.list_connectors!(%{search: "Connector 21"}, page: [limit: 1]).results
    {:ok, view, _html} = live(conn, ~p"/connectors?#{[selected: target.id]}")

    assert render(view) =~ "Page 2 of 2"
    assert has_element?(view, "#connectors-#{target.id}.orpheus-selected")
    assert has_element?(view, "[phx-hook$='FocusSelected'][data-row='connectors-#{target.id}']")
  end

  test "an unknown ?selected is ignored", %{conn: conn} do
    create_connector("Claude")
    {:ok, view, _html} = live(conn, ~p"/connectors?selected=not-a-uuid")

    assert has_element?(view, "#connectors", "Claude")
    refute has_element?(view, ".orpheus-selected")
  end

  test "filters by search, status and provider through the URL", %{conn: conn} do
    create_connector("Work Claude")
    create_connector("Home Claude")
    {:ok, view, _html} = live(conn, ~p"/connectors")

    view |> form("#connector-filters", %{search: "work"}) |> render_change()
    assert_patch(view, ~p"/connectors?page=1&search=work")
    assert has_element?(view, "#connectors", "Work Claude")
    refute has_element?(view, "#connectors", "Home Claude")

    {:ok, view, _html} = live(conn, ~p"/connectors?status=connected")
    refute has_element?(view, "#connectors", "Claude")

    {:ok, view, _html} = live(conn, ~p"/connectors?provider=claude_code&status=bogus")
    assert has_element?(view, "#connectors", "Work Claude")
    assert has_element?(view, "#connectors", "Home Claude")
  end
end
