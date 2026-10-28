defmodule Weworkai.Workflows.MergeTest do
  use Weworkai.DataCase, async: false

  # Start failures are logged with their full detail.
  @moduletag :capture_log

  alias Weworkai.{Agents, Board, BridgeStub, Connectors, ErrorText, Notifications}
  alias Weworkai.{Organization, Workflows}
  alias Weworkai.Workflows.Engine

  setup do
    connector = Connectors.create_connector!(%{name: "Claude", provider: :claude_code})
    %{bridge: BridgeStub.start(), connector: connector}
  end

  defp agent(connector, role) do
    employee =
      Organization.create_employee!(%{
        kind: :agent,
        name: "#{role}",
        agent_role: role,
        connector_id: connector.id
      })

    # Skips :configure, whose check would ask the bridge for its model list.
    employee.agent_id
    |> Agents.get_agent!()
    |> Ash.Changeset.for_update(:assign_role, %{role: role})
    |> Ash.Changeset.force_change_attributes(%{model: "claude-opus-5-5"})
    |> Ash.update!()

    employee
  end

  defp started_runs do
    Stream.repeatedly(fn ->
      receive do
        {:bridge, "POST", "/sessions", body} -> body
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  defp kinds, do: Enum.map(Notifications.recent_notifications!(), & &1.kind)

  # Planned, coded and reviewed on the default workflow: waiting at its "Approve" gate.
  defp ready_task(%{bridge: bridge, connector: connector}) do
    team = Map.new([:planner, :coder, :reviewer, :qa], &{&1, agent(connector, &1)})

    task =
      Board.create_task!(%{
        title: "Greet users",
        description: "Say hello",
        repository: "/repos/app"
      })

    Board.move_task!(task, :todo)
    BridgeStub.step(bridge)
    Board.approve_plan!(Board.get_task!(task.id), team.coder.id)
    BridgeStub.step(bridge)
    BridgeStub.step(bridge)
    BridgeStub.step(bridge)
    started_runs()

    task = Board.get_task!(task.id)
    assert Engine.ready_to_merge?(task)
    task
  end

  describe "merging at the gate" do
    test "the merger merges in the repository; the task waits at its gate again",
         %{bridge: bridge, connector: connector} = context do
      task = ready_task(context)
      agent(connector, :merger)
      assert Engine.mergeable?(task)

      task = Board.merge_task!(task, "main")
      assert %{status: :todo, stage: :merging} = task

      BridgeStub.step(bridge)

      assert [%{"profile" => "merger", "cwd" => "/repos/app", "resume" => nil} = run] =
               started_runs()

      assert run["prompt"] =~ task.worktree_branch
      assert run["prompt"] =~ "into `main`"
      assert run["jsonSchema"]["required"] == ["status", "summary", "branch", "commit"]

      task = Board.get_task!(task.id, load: :current_node)

      assert %{status: :await_human_supervision, stage: nil, merged_into: "main"} = task
      assert task.merge_commit == String.duplicate("a", 40)
      assert task.current_node.label == "Approve"
      assert Engine.ready_to_merge?(task)
      assert :merged in kinds()

      assert %{author: :agent, agent_role: :merger, kind: :outcome} =
               List.last(Board.list_messages!(task.id))
    end

    test "a blocked merge leaves the gate as it was",
         %{bridge: bridge, connector: connector} = context do
      task = ready_task(context)
      agent(connector, :merger)
      BridgeStub.queue(bridge, "merger", BridgeStub.merge("blocked"))

      Board.merge_task!(task)
      BridgeStub.step(bridge)

      assert [%{"prompt" => prompt}] = started_runs()
      assert prompt =~ "the branch checked out in the repository"

      task = Board.get_task!(task.id, load: :current_node)
      assert %{status: :await_human_supervision, stage: nil, merged_into: nil} = task
      assert task.current_node.label == "Approve"
      assert :merge_blocked in kinds()
    end

    test "is refused without a merger, for a name that is no branch, and without code",
         %{connector: connector} = context do
      task = ready_task(context)

      assert {:error, error} = Board.merge_task(task, "main")
      assert ErrorText.readable(error) =~ "No merger agent yet"

      agent(connector, :merger)
      assert {:error, error} = Board.merge_task(task, "main..dev")
      assert ErrorText.readable(error) =~ "is not a branch name"

      planned = Board.create_task!(%{title: "Not coded", repository: "/repos/app"})
      assert {:error, error} = Board.merge_task(planned, "main")
      assert ErrorText.readable(error) =~ "Nothing to merge yet"
    end
  end

  describe "a merger block" do
    defp block(id, kind, fields),
      do: Map.merge(%{id: id, kind: kind, label: fields[:label] || id}, Map.new(fields))

    defp arrow(id, from, to, condition),
      do: %{id: id, from: from, to: to, condition: condition}

    defp auto_merge!(%{connector: connector}) do
      agent(connector, :coder)
      agent(connector, :merger)
      workflow = Workflows.create_workflow!("Auto-merge")

      nodes = [
        block("c", :agent, agent_role: :coder, label: "Code", x: 0),
        block("m", :agent, agent_role: :merger, label: "Merge", merge_branch: "release", x: 200),
        block("d", :column, column_status: :done, label: "Done", x: 400)
      ]

      edges = [arrow("e1", "c", "m", "done"), arrow("e2", "m", "d", "merged")]

      assert {:ok, %{problems: []}} =
               Workflows.save_graph(workflow, %{nodes: nodes, edges: edges})

      task =
        Board.create_task!(%{
          title: "Ship it",
          repository: "/repos/app",
          workflow_id: workflow.id
        })

      Board.move_task!(task, :todo)
    end

    test "merges into its own branch without a human and routes on",
         %{bridge: bridge} = context do
      BridgeStub.queue(bridge, "merger", BridgeStub.merge("merged", "release"))
      task = auto_merge!(context)

      BridgeStub.step(bridge)
      BridgeStub.step(bridge)

      assert [%{"profile" => "coder"}, %{"profile" => "merger", "prompt" => prompt}] =
               started_runs()

      assert prompt =~ "into `release`"
      assert %{status: :done, merged_into: "release"} = Board.get_task!(task.id)
    end

    test "a blocked merge waits for a human on the block", %{bridge: bridge} = context do
      BridgeStub.queue(bridge, "merger", BridgeStub.merge("blocked", "release"))
      task = auto_merge!(context)

      BridgeStub.step(bridge)
      BridgeStub.step(bridge)

      task = Board.get_task!(task.id, load: :current_node)
      assert %{status: :await_human_supervision, stage: :merging} = task
      assert task.current_node.label == "Merge"
      assert Engine.mergeable?(task)
    end

    test "only merger blocks name a branch, and it must be one" do
      problems =
        Workflows.problems(%{
          nodes: [
            block("c", :agent, agent_role: :coder, merge_branch: "main", x: 0),
            block("m", :agent, agent_role: :merger, merge_branch: "-x..y", x: 200)
          ],
          edges: [arrow("e1", "c", "m", "done")]
        })

      assert %{id: "c", message: "Only merger blocks merge into a branch"} in problems
      assert %{id: "m", message: "“-x..y” is not a branch name"} in problems
    end
  end
end
