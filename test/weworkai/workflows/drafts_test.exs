defmodule Weworkai.Workflows.DraftsTest do
  use Weworkai.DataCase, async: false

  @moduletag :capture_log

  alias Weworkai.{Agents, Board, BridgeStub, Connectors, Organization, Workflows}
  alias Weworkai.Workflows.Workflow

  defp blank!(name) do
    Workflow
    |> Ash.Changeset.for_create(:create, %{name: name, empty: true})
    |> Ash.create!()
  end

  # Planner --plan_ready--> Approve --decision--> Done; an unnamed decision is two problems.
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

  defp planner! do
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

    employee
  end

  defp task!(workflow) do
    Board.create_task!(%{
      title: "Greet users",
      repository: "/repos/app",
      workflow_id: workflow.id
    })
  end

  test "a graph with problems is saved as a draft: counted, versioned, stored" do
    workflow = blank!("Draft")
    assert %{problem_count: 1, version: 1} = workflow

    assert {:ok, %{workflow: saved, problems: problems, ids: ids}} =
             Workflows.save_graph(workflow, drawn(nil))

    assert %{problem_count: 2, version: 2} = saved
    assert %{id: "e2", message: "Name this decision: its button shows the name"} in problems
    assert map_size(Workflows.graph!(workflow.id).nodes) == 3

    assert {:ok, %{workflow: fixed, problems: []}} =
             Workflows.save_graph(saved, remap(drawn("accepted"), ids))

    assert %{problem_count: 0, version: 3} = fixed
  end

  test "a save over a newer version changes nothing" do
    workflow = blank!("Two tabs")
    assert {:ok, %{workflow: saved}} = Workflows.save_graph(workflow, drawn("accepted"))

    assert {:error, :stale} = Workflows.save_graph(workflow, %{nodes: [], edges: []})
    assert map_size(Workflows.graph!(workflow.id).nodes) == 3
    assert Workflows.get_workflow!(workflow.id).version == saved.version
  end

  test "a graph that can't be stored is refused whole" do
    workflow = blank!("Dangling")
    graph = update_in(drawn("accepted").edges, &[%{id: "e9", from: "n1", to: "n9"} | &1])

    assert {:error, problems} = Workflows.save_graph(workflow, graph)
    assert %{id: "e9", message: "This arrow ends on a block that doesn't exist"} in problems
    assert %{version: 1} = Workflows.get_workflow!(workflow.id)
    assert Workflows.graph!(workflow.id).nodes == %{}
  end

  test "a workflow with problems starts no task; Continue can still mark it done" do
    planner!()
    workflow = blank!("Broken")
    {:ok, _saved} = Workflows.save_graph(workflow, drawn(nil))
    task = task!(workflow)

    assert {:error, error} = Board.move_task(task, :todo)

    assert Exception.message(error) =~
             "The workflow “Broken” has 2 problems to fix in its editor before tasks can run it."

    assert %{status: :backlog, current_node_id: nil} = Board.get_task!(task.id)
    assert {:ok, %{status: :done}} = Board.continue_task(task, "done")
  end

  test "a task goes on by the version it runs while its workflow is saved with problems" do
    planner!()
    bridge = BridgeStub.start()
    BridgeStub.queue(bridge, "planner", BridgeStub.plan([]))
    workflow = blank!("Edited meanwhile")
    {:ok, %{workflow: workflow, ids: ids}} = Workflows.save_graph(workflow, drawn("accepted"))
    task = Board.move_task!(task!(workflow), :todo)

    {:ok, _saved} = Workflows.save_graph(workflow, remap(drawn(nil), ids))
    BridgeStub.step(bridge)

    task = Board.get_task!(task.id)
    assert %{status: :await_human_supervision, current_node_id: approve} = task
    assert approve == ids["n2"]
    refute Enum.any?(Board.list_messages!(task.id), &(&1.kind == :system))

    assert {:error, reason} = Workflows.upgrade(task)
    assert reason =~ "has 2 problems to fix"

    assert {:ok, %{status: :done, workflow_version: 2}} = Board.decide_task(task, ids["e2"])
  end

  test "a task that starts over runs the latest version, problems and all" do
    planner!()
    workflow = blank!("Started later")
    {:ok, %{workflow: workflow, ids: ids}} = Workflows.save_graph(workflow, drawn("accepted"))
    task = task!(workflow)

    {:ok, _saved} = Workflows.save_graph(workflow, remap(drawn(nil), ids))

    assert {:error, error} = Board.move_task(task, :todo)
    assert Exception.message(error) =~ "“Started later” has 2 problems to fix"
  end

  # Planner (that agent) --plan_ready--> Approve --accepted--> Done.
  defp naming(employee) do
    put_in(drawn("accepted").nodes, [
      %{id: "n1", kind: "agent", label: "Planner", employee_id: employee.id, start: true},
      %{id: "n2", kind: "human", label: "Approve", x: 300},
      %{id: "n3", kind: "column", label: "Done", column_status: "done", x: 600}
    ])
  end

  test "removing an agent a block names counts the problem: the list shows it, tasks are refused" do
    planner = planner!()
    workflow = blank!("Named")
    {:ok, %{workflow: %{problem_count: 0}}} = Workflows.save_graph(workflow, naming(planner))
    task = task!(workflow)

    Organization.destroy_employee!(planner)

    assert %{problem_count: 1, version: 2} = Workflows.get_workflow!(workflow.id)
    assert {:error, error} = Board.move_task(task, :todo)
    assert Exception.message(error) =~ "The workflow “Named” has a problem to fix"
  end

  test "an agent changing role recounts the outcomes its blocks' arrows name" do
    planner = planner!()
    workflow = blank!("Retitled")
    {:ok, _saved} = Workflows.save_graph(workflow, naming(planner))

    [connector] = Connectors.list_connectors!().results
    Organization.update_employee!(planner, %{agent_role: :coder, connector_id: connector.id})
    assert %{problem_count: 1} = Workflows.get_workflow!(workflow.id)

    Organization.update_employee!(planner, %{agent_role: :planner, connector_id: connector.id})
    assert %{problem_count: 0} = Workflows.get_workflow!(workflow.id)
  end

  test "an agent changing role recounts the outcomes its group's arrows name" do
    planner = planner!()
    workflow = blank!("Grouped")

    graph = %{
      nodes: [
        %{id: "g", kind: "group", label: "Plan", start: true},
        %{id: "n1", kind: "agent", label: "Planner", employee_id: planner.id, group_id: "g"},
        %{id: "n2", kind: "human", label: "Approve", x: 300},
        %{id: "n3", kind: "column", label: "Done", column_status: "done", x: 600}
      ],
      edges: [
        %{id: "e1", from: "g", to: "n2", condition: "plan_ready"},
        %{id: "e2", from: "n2", to: "n3", condition: "accepted"}
      ]
    }

    {:ok, %{workflow: %{problem_count: 0}}} = Workflows.save_graph(workflow, graph)

    [connector] = Connectors.list_connectors!().results
    Organization.update_employee!(planner, %{agent_role: :reviewer, connector_id: connector.id})
    assert %{problem_count: 1} = Workflows.get_workflow!(workflow.id)
  end

  defp remap(graph, ids) do
    %{
      nodes: Enum.map(graph.nodes, &%{&1 | id: ids[&1.id]}),
      edges: Enum.map(graph.edges, &%{&1 | id: ids[&1.id], from: ids[&1.from], to: ids[&1.to]})
    }
  end
end
