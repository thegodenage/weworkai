defmodule WeworkaiWeb.WorkflowLiveTest do
  use WeworkaiWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Weworkai.{Connectors, Organization, Workflows}
  alias Weworkai.Workflows.Workflow

  defp blank!(name) do
    Workflow
    |> Ash.Changeset.for_create(:create, %{name: name, empty: true})
    |> Ash.create!()
  end

  defp editor_data(view, key) do
    view
    |> element("#workflow-editor")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-#{key}")
    |> hd()
    |> Jason.decode!()
  end

  # Coder --done--> Approve --accepted--> Done, in the editor's own ids.
  defp drawn do
    %{
      "nodes" => [
        %{
          "id" => "n1",
          "kind" => "agent",
          "label" => "Coder",
          "agent_role" => "coder",
          "start" => true
        },
        %{"id" => "n2", "kind" => "human", "label" => "Approve", "x" => 300},
        %{
          "id" => "n3",
          "kind" => "column",
          "label" => "Done",
          "column_status" => "done",
          "x" => 600
        }
      ],
      "edges" => [
        %{"id" => "e1", "from" => "n1", "to" => "n2", "condition" => "done"},
        %{"id" => "e2", "from" => "n2", "to" => "n3", "condition" => "accepted"}
      ]
    }
  end

  test "hands the stored graph, its problems and the catalog to the editor", %{conn: conn} do
    default = Workflows.default_workflow!()
    {:ok, view, _html} = live(conn, ~p"/workflows/#{default.id}")

    assert has_element?(view, "#workflow-name", default.name)
    assert has_element?(view, "#workflow-default")
    assert has_element?(view, "#workflow-editor[phx-hook=WorkflowEditor][phx-update=ignore]")

    for id <-
          ~w(palette-role-planner palette-human-any palette-column-done palette-group palette-triage wf-save),
        do: assert(has_element?(view, "##{id}"))

    refute has_element?(view, "#palette-column-await_human_supervision")

    %{"nodes" => nodes, "edges" => edges} = editor_data(view, "graph")
    assert length(nodes) == 7 and length(edges) == 8
    assert %{"label" => "Planner", "start" => true} = Enum.find(nodes, & &1["start"])
    assert Enum.any?(edges, &(&1["condition"] == "findings" and &1["iterations"] == 3))
    assert editor_data(view, "problems") == []

    assert %{"outcomes" => ["clean", "findings"]} =
             Enum.find(editor_data(view, "catalog")["roles"], &(&1["value"] == "reviewer"))

    assert editor_data(view, "catalog")["triage_outcomes"] == ~w(high medium low clean)
  end

  test "saves a drawn graph and maps the editor's ids to the stored ones", %{conn: conn} do
    workflow = blank!("Drawn")
    {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}")
    assert editor_data(view, "graph") == %{"nodes" => [], "edges" => []}

    assert editor_data(view, "version") == 1
    render_hook(view, "save", Map.put(drawn(), "version", 1))
    assert_reply(view, %{ok: true, ids: ids, problems: [], version: 2})

    assert Map.keys(ids) |> Enum.sort() == ~w(e1 e2 n1 n2 n3)
    graph = Workflows.graph!(workflow.id)

    assert graph.nodes |> Map.keys() |> Enum.sort() ==
             Enum.sort([ids["n1"], ids["n2"], ids["n3"]])

    assert graph.start_id == ids["n1"]

    # Saving again with the stored ids keeps them.
    again = %{
      "nodes" => Enum.map(drawn()["nodes"], &%{&1 | "id" => ids[&1["id"]]}),
      "edges" =>
        Enum.map(drawn()["edges"], fn edge ->
          %{edge | "id" => ids[edge["id"]], "from" => ids[edge["from"]], "to" => ids[edge["to"]]}
        end)
    }

    render_hook(view, "save", Map.put(again, "version", 2))
    assert_reply(view, %{ok: true, ids: kept, version: 3})
    assert Enum.all?(kept, fn {sent, stored} -> sent == stored end)
  end

  test "an agent block's own instructions are saved and handed back to the editor", %{conn: conn} do
    workflow = blank!("Instructed")
    {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}")

    instructed =
      update_in(drawn()["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "n1"} = node -> Map.put(node, "prompt", "Keep it small.\nNo new deps.")
          node -> node
        end)
      end)

    render_hook(view, "save", Map.put(instructed, "version", 1))
    assert_reply(view, %{ok: true, ids: ids, problems: []})

    {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}")
    nodes = editor_data(view, "graph")["nodes"]

    assert %{"prompt" => "Keep it small.\nNo new deps."} =
             Enum.find(nodes, &(&1["id"] == ids["n1"]))

    assert %{"prompt" => nil} = Enum.find(nodes, &(&1["id"] == ids["n2"]))
  end

  test "a save drawn from an older version (another tab's) is refused", %{conn: conn} do
    workflow = blank!("Two tabs")
    {:ok, first, _html} = live(conn, ~p"/workflows/#{workflow.id}")
    {:ok, second, _html} = live(conn, ~p"/workflows/#{workflow.id}")

    render_hook(first, "save", Map.put(drawn(), "version", 1))
    assert_reply(first, %{ok: true, version: 2})

    render_hook(second, "save", %{"nodes" => [], "edges" => [], "version" => 1})
    assert_reply(second, %{ok: false, stale: true, version: 2})
    assert map_size(Workflows.graph!(workflow.id).nodes) == 3

    # Saving over it on purpose: with the newer version.
    render_hook(second, "save", %{"nodes" => [], "edges" => [], "version" => 2})
    assert_reply(second, %{ok: true, version: 3})
  end

  test "a graph with problems is saved as a draft; its problems come back by id", %{conn: conn} do
    workflow = blank!("Broken")
    {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}")

    broken =
      drawn()
      |> update_in(["edges"], fn [first, second] -> [first, %{second | "condition" => nil}] end)
      |> update_in(
        ["nodes"],
        &(&1 ++
            [
              %{
                "id" => "n4",
                "kind" => "agent",
                "label" => "Lost",
                "agent_role" => "reviewer",
                "x" => 900
              }
            ])
      )

    render_hook(view, "validate", broken)
    assert_reply(view, %{problems: problems})
    assert %{id: "e2", message: "Name this decision: its button shows the name"} in problems
    assert %{id: "n4", message: "This block can't be reached from the start block"} in problems

    render_hook(view, "save", Map.put(broken, "version", 1))
    assert_reply(view, %{ok: true, problems: ^problems, version: 2})
    assert map_size(Workflows.graph!(workflow.id).nodes) == 4
    assert Workflows.get_workflow!(workflow.id).problem_count == length(problems)

    render_hook(view, "validate", drawn())
    assert_reply(view, %{problems: []})
  end

  test "a graph that can't be stored is refused with its problems", %{conn: conn} do
    workflow = blank!("Dangling")
    {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}")
    dangling = update_in(drawn()["edges"], &[%{"id" => "e9", "from" => "n1", "to" => "n9"} | &1])

    render_hook(view, "save", Map.put(dangling, "version", 1))
    assert_reply(view, %{ok: false, problems: problems})
    assert %{id: "e9", message: "This arrow ends on a block that doesn't exist"} in problems
    assert Workflows.graph!(workflow.id).nodes == %{}
  end

  test "an agent block whose agent was removed shows a problem on load", %{conn: conn} do
    connector = Connectors.create_connector!(%{name: "Claude", provider: :claude_code})

    employee =
      Organization.create_employee!(%{
        kind: :agent,
        name: "Temp",
        agent_role: :coder,
        connector_id: connector.id
      })

    workflow = blank!("Orphaned")

    {:ok, _} =
      Workflows.save_graph(workflow, %{
        nodes: [%{id: "n1", kind: "agent", label: "Temp", employee_id: employee.id}],
        edges: []
      })

    Organization.destroy_employee!(employee)
    {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}")

    assert [%{"message" => "Its agent was removed: pick an agent or a role"}] =
             editor_data(view, "problems")
  end

  test "the version history follows saves, counts the tasks on each and restores one",
       %{conn: conn} do
    workflow = blank!("History")
    {:ok, view, _html} = live(conn, ~p"/workflows/#{workflow.id}")

    assert has_element?(view, "#wf-version", "v1")
    refute has_element?(view, "#wf-versions-list")

    render_hook(view, "save", Map.put(drawn(), "version", 1))
    assert_reply(view, %{ok: true, ids: ids, version: 2})
    assert has_element?(view, "#wf-version", "v2")

    task = Weworkai.Board.create_task!(%{title: "Pinned", workflow_id: workflow.id})
    Weworkai.Board.advance_task!(task, %{current_node_id: ids["n2"]})

    view |> element("#wf-versions-toggle") |> render_click()
    assert has_element?(view, "#wf-version-2[data-current]")
    assert has_element?(view, "#wf-version-2-tasks", "1 task on it")
    assert has_element?(view, "#wf-version-1-tasks", "0 tasks on it")
    refute has_element?(view, "#wf-version-2-restore")

    view |> element("#wf-version-1-restore") |> render_click()

    path = ~p"/workflows/#{workflow.id}"
    assert {^path, %{"info" => "Restored v1 as v3."}} = assert_redirect(view)
    assert %{version: 3} = Workflows.get_workflow!(workflow.id)
    assert Workflows.graph!(workflow.id).nodes == %{}
  end

  test "an unknown workflow goes back to the list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/workflows"}}} =
             live(conn, ~p"/workflows/#{Ecto.UUID.generate()}")
  end
end
