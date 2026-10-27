defmodule Weworkai.Workflows.VersionsTest do
  use Weworkai.DataCase, async: false

  @moduletag :capture_log

  alias Weworkai.{Agents, Board, BridgeStub, Connectors, Organization, Workflows}
  alias Weworkai.Workflows.{Engine, Workflow}

  setup do
    connector = Connectors.create_connector!(%{name: "Claude", provider: :claude_code})

    employee =
      Organization.create_employee!(%{
        kind: :agent,
        name: "Planner",
        agent_role: :planner,
        connector_id: connector.id
      })

    employee.agent_id
    |> Agents.get_agent!()
    |> Ash.Changeset.for_update(:assign_role, %{role: :planner})
    |> Ash.Changeset.force_change_attributes(%{model: "claude-opus-5-5"})
    |> Ash.update!()

    bridge = BridgeStub.start()
    BridgeStub.queue(bridge, "planner", BridgeStub.plan([]))
    %{bridge: bridge}
  end

  # Planner --plan_ready--> Approve --decision--> Done.
  defp drawn(decision) do
    %{
      nodes: [
        %{id: "n1", kind: "agent", label: "Planner", agent_role: "planner", start: true},
        %{id: "n2", kind: "human", label: "Approve", x: 300},
        %{id: "n3", kind: "column", label: "Done", column_status: "done", x: 600}
      ],
      edges: [
        %{id: "e1", from: "n1", to: "n2", condition: "plan_ready"},
        %{id: "e2", from: "n2", to: "n3", condition: decision}
      ]
    }
  end

  # Planner --plan_ready--> Second look --accepted--> Done: Approve is gone.
  defp second_look do
    %{
      nodes: [
        %{id: "n1", kind: "agent", label: "Planner", agent_role: "planner", start: true},
        %{id: "n4", kind: "human", label: "Second look", x: 300},
        %{id: "n3", kind: "column", label: "Done", column_status: "done", x: 600}
      ],
      edges: [
        %{id: "e1", from: "n1", to: "n4", condition: "plan_ready"},
        %{id: "e3", from: "n4", to: "n3", condition: "accepted"}
      ]
    }
  end

  defp remap(graph, ids) do
    id = &Map.get(ids, &1, &1)

    %{
      nodes: Enum.map(graph.nodes, &%{&1 | id: id.(&1.id)}),
      edges: Enum.map(graph.edges, &%{&1 | id: id.(&1.id), from: id.(&1.from), to: id.(&1.to)})
    }
  end

  defp saved!(name) do
    workflow =
      Workflow
      |> Ash.Changeset.for_create(:create, %{name: name, empty: true})
      |> Ash.create!()

    {:ok, %{workflow: workflow, ids: ids}} = Workflows.save_graph(workflow, drawn("accepted"))
    {workflow, ids}
  end

  # On the Approve block of the version it started on.
  defp waiting!(workflow, bridge) do
    task =
      Board.create_task!(%{
        title: "Greet users",
        repository: "/repos/app",
        workflow_id: workflow.id
      })

    Board.move_task!(task, :todo)
    BridgeStub.step(bridge)
    Board.get_task!(task.id)
  end

  defp decision_labels(task) do
    task |> Engine.decisions(Workflows.running!(task).graph) |> Enum.map(& &1.edge.condition)
  end

  test "creating and saving a workflow records each version, newest first" do
    {workflow, _ids} = saved!("Versioned")

    assert [%{number: 2, problem_count: 0} = latest, %{number: 1, problem_count: 1}] =
             Workflows.list_versions!(workflow.id)

    assert workflow.version == 2
    assert length(latest.graph["nodes"]) == 3
  end

  test "the migration keeps every existing workflow's graph as its version 1" do
    default = Workflows.default_workflow!()
    version = Workflows.get_version!(default.id, 1)

    assert length(version.graph["nodes"]) == map_size(Workflows.graph!(default.id).nodes)
  end

  test "a task runs the version it started on while the workflow is edited",
       %{bridge: bridge} do
    {workflow, ids} = saved!("Edited")

    task =
      Board.create_task!(%{
        title: "Greet users",
        repository: "/repos/app",
        workflow_id: workflow.id
      })

    task = Board.move_task!(task, :todo)
    assert task.workflow_version == 2

    {:ok, _saved} = Workflows.save_graph(workflow, remap(second_look(), ids))
    BridgeStub.step(bridge)

    task = Board.get_task!(task.id)
    assert %{status: :await_human_supervision, workflow_version: 2} = task
    assert task.current_node.label == "Approve"
    assert decision_labels(task) == ["accepted"]

    assert {:error, "Its block is not in v3: it finishes on v2."} = Workflows.upgrade(task)
    assert {:error, _refused} = Board.upgrade_task_workflow(task)

    assert {:ok, %{status: :done, current_node_id: nil}} = Board.decide_task(task, ids["e2"])
  end

  test "a task moves to the latest version on its block; what comes next follows it",
       %{bridge: bridge} do
    {workflow, ids} = saved!("Renamed")
    task = waiting!(workflow, bridge)

    {:ok, %{workflow: %{version: 3}}} =
      Workflows.save_graph(workflow, remap(drawn("ship it"), ids))

    assert decision_labels(task) == ["accepted"]

    assert {:ok, task} = Board.upgrade_task_workflow(task)
    assert %{workflow_version: 3, current_node_id: approve} = task
    assert approve == ids["n2"]
    assert decision_labels(task) == ["ship it"]

    assert [%{kind: :upgrade, label: "Moved from v2 to v3", node_id: ^approve}] =
             Enum.filter(Board.list_events!(task.id), &(&1.kind == :upgrade))
  end

  test "a task that starts over takes the latest version", %{bridge: bridge} do
    {workflow, ids} = saved!("Restarted")
    task = waiting!(workflow, bridge)
    {:ok, task} = Board.continue_task(task, "done")
    assert task.workflow_version == 2

    {:ok, _saved} = Workflows.save_graph(workflow, remap(second_look(), ids))
    {:ok, task} = Board.move_task(task, :todo)
    BridgeStub.step(bridge)

    task = Board.get_task!(task.id)
    assert %{workflow_version: 3} = task
    assert task.current_node.label == "Second look"
  end

  test "restoring a version saves its graph as the newest, under the same ids" do
    {workflow, ids} = saved!("Rolled back")
    {:ok, %{workflow: edited}} = Workflows.save_graph(workflow, remap(second_look(), ids))

    {:ok, %{workflow: restored}} =
      Workflows.restore_version(edited, Workflows.get_version!(workflow.id, 2))

    assert restored.version == 4
    graph = Workflows.graph!(workflow.id)
    assert Enum.sort(Map.keys(graph.nodes)) == Enum.sort([ids["n1"], ids["n2"], ids["n3"]])
    assert Enum.map(Workflows.list_versions!(workflow.id), & &1.number) == [4, 3, 2, 1]
  end
end
