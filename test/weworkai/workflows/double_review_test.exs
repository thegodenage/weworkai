defmodule Weworkai.Workflows.DoubleReviewTest do
  # The seeded "Double review" template (docs/workflows.md, "Templates") run end to end on
  # the bridge stub: which agents run, in which order, and how its two counters (the review
  # group's ×2 loop and the findings arrow's max 3) interact.
  use Weworkai.DataCase, async: false

  @moduletag :capture_log

  require Ash.Query

  alias Weworkai.{Agents, Board, BridgeStub, Connectors, Notifications, Organization, Workflows}
  alias Weworkai.Workflows.{Engine, Graph, Workflow}

  setup do
    connector = Connectors.create_connector!(%{name: "Claude", provider: :claude_code})

    for role <- [:planner, :coder, :reviewer, :qa] do
      employee =
        Organization.create_employee!(%{
          kind: :agent,
          name: "#{role}",
          agent_role: role,
          connector_id: connector.id
        })

      employee.agent_id
      |> Agents.get_agent!()
      |> Ash.Changeset.for_update(:assign_role, %{role: role})
      |> Ash.Changeset.force_change_attributes(%{model: "claude-opus-5-5"})
      |> Ash.update!()
    end

    template =
      Workflow
      |> Ash.Query.filter(template == :double_review)
      |> Ash.read_one!()

    %{bridge: BridgeStub.start(), workflow: Workflows.create_workflow!("Mine", template.id)}
  end

  # Planned, approved and handed to the coder: the next step runs the coder.
  defp coding!(bridge, workflow) do
    task =
      Board.create_task!(%{
        title: "Greet users",
        description: "Say hello",
        repository: "/repos/app",
        workflow_id: workflow.id
      })

    Board.move_task!(task, :todo)
    BridgeStub.step(bridge)
    task = Board.approve_plan!(Board.get_task!(task.id))
    flush_bridge()
    task
  end

  defp run(bridge, steps) do
    for _step <- 1..steps, do: BridgeStub.step(bridge)
    started_profiles()
  end

  defp started_profiles do
    receive do
      {:bridge, "POST", "/sessions", body} -> [body["profile"] | started_profiles()]
      {:bridge, _method, _path, _body} -> started_profiles()
    after
      0 -> []
    end
  end

  defp flush_bridge, do: started_profiles()

  defp at(task) do
    task = Board.get_task!(task.id, load: :current_node)
    task.current_node.label
  end

  @full_review ~w(reviewer qa reviewer qa)

  test "the template copies with its graph: no problems, three fix rounds", %{workflow: workflow} do
    assert workflow.problem_count == 0
    graph = Workflows.graph!(workflow.id)
    assert map_size(graph.nodes) == 8
    assert Engine.fix_round_limit(graph) == 3
    assert {:ok, _graph} = Graph.validate(params(graph), %{})
  end

  test "clean: exactly two full reviews (code reviewer, docker reviewer, twice), then Approve",
       %{bridge: bridge, workflow: workflow} do
    task = coding!(bridge, workflow)

    assert ["coder" | @full_review] = run(bridge, 5)

    task = Board.get_task!(task.id)
    assert at(task) == "Approve"
    assert %{status: :await_human_supervision, review_round: 0, findings: []} = task
    assert Engine.ready_to_merge?(task)
    assert [%{kind: :ready_to_merge} | _] = Notifications.recent_notifications!()
    assert run(bridge, 1) == []
  end

  test "findings in the first pass go straight to the coder; after the fix both passes run again",
       %{bridge: bridge, workflow: workflow} do
    task = coding!(bridge, workflow)
    BridgeStub.queue(bridge, "reviewer", BridgeStub.findings(1))

    # The docker reviewer still runs in that pass and adds its own to the round's.
    assert ~w(coder reviewer qa coder) = run(bridge, 4)
    assert Board.get_task!(task.id).review_round == 1

    assert @full_review = run(bridge, 4)
    task = Board.get_task!(task.id)
    assert at(task) == "Approve"
    assert %{review_round: 1, findings: []} = task
  end

  test "findings in the second pass send the coder back too; the next review starts at pass one",
       %{bridge: bridge, workflow: workflow} do
    task = coding!(bridge, workflow)
    BridgeStub.queue(bridge, "qa", BridgeStub.findings(0))
    BridgeStub.queue(bridge, "qa", BridgeStub.findings(2))

    assert ["coder" | @full_review] ++ ["coder"] == run(bridge, 6)
    assert Board.get_task!(task.id).review_round == 1

    assert @full_review = run(bridge, 4)
    assert at(task) == "Approve"
  end

  test "after three fix rounds the findings go on to Approve, attached",
       %{bridge: bridge, workflow: workflow} do
    task = coding!(bridge, workflow)
    for _round <- 1..4, do: BridgeStub.queue(bridge, "reviewer", BridgeStub.findings(1))

    # Four reviews cut short by findings, three fixes between them.
    assert ~w(coder reviewer qa coder reviewer qa coder reviewer qa coder reviewer qa) ==
             run(bridge, 12)

    task = Board.get_task!(task.id)
    assert at(task) == "Approve"
    assert %{review_round: 3, findings: [%{source: :reviewer}]} = task

    assert [%{kind: :ready_to_merge, body: "1 findings are still open after 3 fix rounds."} | _] =
             Notifications.recent_notifications!()
  end

  test "a human dragging the task into review gets two full passes too",
       %{bridge: bridge, workflow: workflow} do
    task = coding!(bridge, workflow)
    run(bridge, 5)

    Board.move_task!(Board.get_task!(task.id), :review)
    assert @full_review = run(bridge, 4)
    assert at(task) == "Approve"
  end

  defp params(graph) do
    %{
      nodes:
        Enum.map(Map.values(graph.nodes), fn node ->
          node
          |> Map.take([:id, :kind, :agent_role, :column_status, :label, :x, :y, :width])
          |> Map.merge(%{height: node.height, start: node.start, group_id: node.group_id})
        end),
      edges:
        Enum.map(graph.edges, fn edge ->
          edge
          |> Map.take([:id, :condition, :iterations, :from_port, :to_port])
          |> Map.merge(%{from: edge.from_node_id, to: edge.to_node_id})
        end)
    }
  end
end
