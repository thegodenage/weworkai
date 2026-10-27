defmodule Weworkai.Audit.TimelineTest do
  use Weworkai.DataCase

  import Ecto.Query

  alias Weworkai.{Board, Connectors, Organization, Repo, Scheduling, Workflows}
  alias Weworkai.Audit.Timeline
  alias Weworkai.Workflows.Graph

  setup do
    task = Board.create_task!(%{title: "Audited"})
    graph = Workflows.graph!(task.workflow_id)
    connector = Connectors.create_connector!(%{name: "Claude", provider: :claude_code})

    planner =
      Organization.create_employee!(%{
        kind: :agent,
        name: "Planner Pat",
        agent_role: :planner,
        connector_id: connector.id
      })

    %{task: task, block: Graph.node(graph, graph.start_id), planner: planner}
  end

  test "nothing happened yet: no span", %{task: task} do
    assert %Timeline{from: nil, lanes: []} = Timeline.build(task)
  end

  test "a job is a bar in its block's lane; the rest of the span waited on people",
       %{task: task, block: block, planner: planner} do
    now = DateTime.utc_now()
    ended_job(task, planner, block, now, queued: 10, started: 9, finished: 4)
    Board.move_task!(task, :done)

    timeline = Timeline.build(Board.get_task!(task.id), :block, now)

    assert [%{label: label, sublabel: "Planner Pat", bars: [bar]}] = timeline.lanes
    assert label == block.label
    assert bar.queued_ms == 60_000
    assert bar.running_ms == 300_000
    assert [%{kind: :move, label: "Moved to Done"}] = timeline.points
    assert timeline.totals.waiting_ms >= 240_000
    assert [%{kind: :lane, ms: 360_000} | _] = timeline.breakdown
    refute timeline.live?
  end

  test "a move is labelled with the column the person chose, not where the workflow sent it" do
    {:ok, workflow} = Workflows.create_workflow("Straight to done", nil, %{empty: true})

    {:ok, %{problems: []}} =
      Workflows.save_graph(workflow, %{
        nodes: [%{id: "n1", kind: "column", label: "Finish", column_status: "done"}],
        edges: []
      })

    task = Board.create_task!(%{title: "Short trip", workflow_id: workflow.id})
    assert %{status: :done} = Board.move_task!(task, :todo)

    assert [%{kind: :move, label: "Moved to Todo"}] = Timeline.build(task).points
  end

  test "by agent, a lane per employee", %{task: task, block: block, planner: planner} do
    now = DateTime.utc_now()
    ended_job(task, planner, block, now, queued: 6, started: 5, finished: 3)
    ended_job(task, planner, block, now, queued: 2, started: 2, finished: 1)

    timeline = Timeline.build(task, :agent, now)

    assert [%{label: "Planner Pat", sublabel: "Planner", bars: [_, _]}] = timeline.lanes
  end

  test "durations read short" do
    assert Timeline.duration(0) == "0s"
    assert Timeline.duration(42_000) == "42s"
    assert Timeline.duration(192_000) == "3m 12s"
    assert Timeline.duration(3_600_000) == "1h"
    assert Timeline.duration(7_500_000) == "2h 5m"
    assert Timeline.duration(273_600_000) == "3d 4h"
  end

  # A done job queued, started and finished the given minutes before `now`.
  defp ended_job(task, agent_employee, block, now, minutes) do
    job =
      Scheduling.create_job!(%{
        task_id: task.id,
        agent_id: agent_employee.agent_id,
        node_id: block.id,
        stage: :planning,
        folder: task.repository,
        prompt: "Plan"
      })

    at = &(now |> DateTime.add(-minutes[&1] * 60, :second) |> DateTime.to_naive())

    Repo.update_all(from(j in "jobs", where: j.id == type(^job.id, Ecto.UUID)),
      set: [
        status: "done",
        inserted_at: at.(:queued),
        started_at: at.(:started),
        finished_at: at.(:finished)
      ]
    )
  end
end
