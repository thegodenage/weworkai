defmodule WeworkaiWeb.CommandPaletteTest do
  use WeworkaiWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Weworkai.{Board, Organization, Workflows}

  defp open(view, recent \\ []) do
    view |> element("#command-palette") |> render_hook("open", %{recent: recent})
    view
  end

  defp search(view, query) do
    view |> element("#command-palette-form") |> render_change(%{query: query})
  end

  defp open_dashboard(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard")
    open(view)
  end

  test "every page has the palette, listing actions and pages once opened", %{conn: conn} do
    for path <- [~p"/", ~p"/dashboard", ~p"/employees"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#command-palette-dialog[role=dialog]")
      refute has_element?(view, "[role=option]")

      open(view)
      assert has_element?(view, "#command-palette-group-actions [role=option]", "New task")
      assert has_element?(view, "#command-palette-group-pages [role=option]", "Audit")
      refute has_element?(view, "#command-palette-group-tasks")

      view |> element("#command-palette") |> render_hook("close", %{})
      refute has_element?(view, "[role=option]")
    end
  end

  test "a query finds tasks, workflows and employees, best match first", %{conn: conn} do
    task = Board.create_task!(%{title: "Greet users"})
    Board.create_task!(%{title: "Regenerate tokens"})
    workflow = Workflows.create_workflow!("Greeting flow")
    employee = Organization.create_employee!(%{kind: :human, name: "Greta", role: "QA"})
    view = open_dashboard(conn)

    search(view, "gre")

    assert has_element?(
             view,
             "#command-palette-group-tasks [role=option]:first-of-type[data-href='/tasks/#{task.id}']",
             "Greet users"
           )

    assert has_element?(view, "#command-palette-group-tasks [role=option]", "Regenerate tokens")

    assert has_element?(
             view,
             "#command-palette-group-workflows [data-href='/workflows/#{workflow.id}']"
           )

    assert has_element?(
             view,
             "#command-palette-group-employees [data-href='/employees/#{employee.id}/edit']",
             "Human"
           )

    refute has_element?(view, "#command-palette-group-pages")
  end

  test "matched characters are highlighted", %{conn: conn} do
    Board.create_task!(%{title: "Greet users"})

    matches =
      conn
      |> open_dashboard()
      |> search("gtu")
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#command-palette-group-tasks [role=option] .text-primary")

    assert Enum.map(matches, &LazyHTML.text/1) == ["G", "t", "u"]
  end

  test "a query nothing matches says so", %{conn: conn} do
    view = open_dashboard(conn)
    search(view, "zzzqqq")
    assert has_element?(view, "#command-palette-empty")
    refute has_element?(view, "[role=option]")
  end

  test "opening shows the recent picks the browser sent, keeping only app paths", %{conn: conn} do
    view = open_dashboard(conn)
    search(view, "audit")

    open(view, [
      %{label: "Greet users", href: "/tasks/1", kind: "Tasks"},
      %{label: "Elsewhere", href: "//evil.example", kind: "Pages"},
      %{label: "Outside", href: "https://evil.example", kind: "Pages"}
    ])

    assert has_element?(
             view,
             "#command-palette-group-recent [data-href='/tasks/1']",
             "Greet users"
           )

    assert has_element?(view, "#command-palette-group-recent [role=option]", "Tasks")
    refute has_element?(view, "#command-palette-group-recent [data-href*='evil']")
    assert has_element?(view, "#command-palette-group-actions")
  end
end
