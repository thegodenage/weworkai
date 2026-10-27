defmodule Weworkai.Board.TaskDependencyTest do
  use Weworkai.DataCase, async: false

  alias Weworkai.{Board, Connectors, Notifications, Organization, Scheduling, Workflows}

  defp task(title), do: Board.create_task!(%{title: title, repository: "~/app"})

  defp agent_id do
    connector = Connectors.create_connector!(%{name: "Claude", provider: :claude_code})

    Organization.create_employee!(%{
      kind: :agent,
      name: "Ada",
      agent_role: :coder,
      connector_id: connector.id
    }).agent_id
  end

  defp queue(task, agent_id, attrs \\ %{}) do
    Scheduling.create_job!(
      Map.merge(%{task_id: task.id, agent_id: agent_id, folder: "~/app", prompt: "Go"}, attrs)
    )
  end

  defp due_task_ids, do: Enum.map(Scheduling.due_scheduled_jobs!(), & &1.job.task_id)

  defp reason(result) do
    {:error, %Ash.Error.Invalid{errors: [%{message: message}]}} = result
    message
  end

  describe "blockers" do
    test "a blocked task shows what it waits on" do
      api = task("API")
      ui = task("UI")
      Board.add_blocker!(ui.id, api.id)

      ui = Board.get_task!(ui.id, load: [:blocked, :open_blocker_titles])
      assert ui.blocked
      assert ui.open_blocker_titles == ["API"]
      assert Board.get_task!(api.id).dependent_ids == [ui.id]
    end

    test "a task can't wait on itself, directly or through other tasks" do
      a = task("A")
      b = task("B")
      c = task("C")
      Board.add_blocker!(b.id, a.id)
      Board.add_blocker!(c.id, b.id)

      assert reason(Board.add_blocker(a.id, a.id)) =~ "wait on each other"
      assert reason(Board.add_blocker(a.id, b.id)) =~ "wait on each other"
      assert reason(Board.add_blocker(a.id, c.id)) =~ "wait on each other"
      assert {:ok, _} = Board.add_blocker(c.id, a.id)
    end

    test "the scheduler holds a blocked task's work until its blockers close" do
      agent_id = agent_id()
      api = task("API")
      docs = task("Docs")
      ui = task("UI")
      Board.add_blocker!(ui.id, api.id)
      Board.add_blocker!(ui.id, docs.id)
      queue(ui, agent_id)

      refute ui.id in due_task_ids()

      Board.move_task!(api, :done)
      refute ui.id in due_task_ids()

      Board.move_task!(docs, :canceled)
      assert ui.id in due_task_ids()
    end

    test "a question about a blocked task is answered meanwhile" do
      agent_id = agent_id()
      api = task("API")
      ui = task("UI")
      Board.add_blocker!(ui.id, api.id)
      queue(ui, agent_id, %{stage: :ask})

      assert ui.id in due_task_ids()
    end

    test "removing the last blocker releases the task" do
      agent_id = agent_id()
      api = task("API")
      ui = task("UI")
      Board.add_blocker!(ui.id, api.id)
      queue(ui, agent_id)

      ui.id |> Board.get_dependency!(api.id) |> Board.remove_blocker!()

      assert ui.id in due_task_ids()
    end

    test "the last blocker closing notifies the task and marks its timeline" do
      api = task("API")
      docs = task("Docs")
      ui = task("UI")
      Board.add_blocker!(ui.id, api.id)
      Board.add_blocker!(ui.id, docs.id)

      Board.move_task!(api, :done)
      assert Notifications.recent_notifications!() |> Enum.filter(&(&1.kind == :unblocked)) == []

      Board.move_task!(docs, :done)

      assert [%{task_id: task_id, title: "Unblocked: UI"}] =
               Enum.filter(Notifications.recent_notifications!(), &(&1.kind == :unblocked))

      assert task_id == ui.id

      assert [%{label: "Unblocked by Docs"}] =
               ui.id |> Board.list_events!() |> Enum.filter(&(&1.kind == :unblocked))
    end
  end

  describe "sub-tasks" do
    test "a sub-task inherits its parent's repository and workflow, on its latest version" do
      parent = Board.create_task!(%{title: "Epic", repository: "~/Projects/shop"})
      child = Board.create_subtask!(parent.id, "Checkout")

      assert child.parent_id == parent.id
      assert child.repository == "~/Projects/shop"
      assert child.workflow_id == parent.workflow_id
      assert child.workflow_version == Workflows.get_workflow!(parent.workflow_id).version
    end

    test "the parent counts its open sub-tasks and those done" do
      parent = task("Epic")
      first = Board.create_subtask!(parent.id, "One")
      second = Board.create_subtask!(parent.id, "Two")
      dropped = Board.create_subtask!(parent.id, "Three")
      Board.move_task!(first, :done)
      Board.move_task!(dropped, :canceled)

      assert %{child_count: 2, done_child_count: 1} = Board.get_task!(parent.id)
      assert Board.get_task!(second.id).parent_id == parent.id
    end
  end
end
