defmodule Weworkai.Repo.Migrations.Workflows do
  @moduledoc """
  User-defined workflows (docs/workflows.md). Generated with
  `mix ash_postgres.generate_migrations`, then reordered by hand so that the default
  workflow is seeded and every existing task runs it from the block matching its stage
  before `tasks.workflow_id` becomes required.
  """

  use Ecto.Migration

  def up do
    create table(:workflows, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :position, :bigint, null: false, default: 0

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create table(:workflow_nodes, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :workflow_id,
          references(:workflows,
            column: :id,
            name: "workflow_nodes_workflow_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :kind, :text, null: false
      add :agent_role, :text
      add :column_status, :text
      add :label, :text, null: false
      add :x, :bigint, null: false, default: 0
      add :y, :bigint, null: false, default: 0
      add :width, :bigint
      add :height, :bigint
      add :start, :boolean, null: false, default: false

      add :employee_id,
          references(:employees,
            column: :id,
            name: "workflow_nodes_employee_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :nilify_all
          )

      add :group_id,
          references(:workflow_nodes,
            column: :id,
            name: "workflow_nodes_group_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          )
    end

    create table(:workflow_edges, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :workflow_id,
          references(:workflows,
            column: :id,
            name: "workflow_edges_workflow_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :from_node_id,
          references(:workflow_nodes,
            column: :id,
            name: "workflow_edges_from_node_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :to_node_id,
          references(:workflow_nodes,
            column: :id,
            name: "workflow_edges_to_node_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :condition, :text
      add :iterations, :bigint
      add :from_port, :text, null: false, default: "right"
      add :to_port, :text, null: false, default: "left"
    end

    alter table(:tasks) do
      add :edge_counts, :map, null: false, default: %{}
      add :node_counts, :map, null: false, default: %{}
      add :workflow_id, :uuid
      add :current_node_id, :uuid
    end

    flush()

    workflow = seed_default()
    backfill(workflow)

    alter table(:tasks) do
      modify :workflow_id,
             references(:workflows,
               column: :id,
               name: "tasks_workflow_id_fkey",
               type: :uuid,
               prefix: "public"
             ),
             null: false
    end
  end

  # The hard-coded flow this replaces, as a graph. Both reviewers see every round, and the
  # docker reviewer's findings (the round's, the code reviewer's included) send the coder
  # back at most three times, as before.
  @nodes [
    planner: {"agent", "Planner", "planner", nil, 0, true},
    approve_plan: {"human", "Approve plan", nil, nil, 260, false},
    coder: {"agent", "Coder", "coder", nil, 520, false},
    reviewer: {"agent", "Reviewer", "reviewer", nil, 780, false},
    docker_reviewer: {"agent", "Docker reviewer", "qa", nil, 1040, false},
    approve: {"human", "Approve", nil, nil, 1300, false},
    done: {"column", "Done", nil, "done", 1560, false}
  ]

  @edges [
    {:planner, :approve_plan, "plan_ready", nil, "right", "left"},
    {:approve_plan, :coder, "approved", nil, "right", "left"},
    {:coder, :reviewer, "done", nil, "right", "left"},
    {:reviewer, :docker_reviewer, nil, nil, "right", "left"},
    {:docker_reviewer, :coder, "findings", 3, "bottom", "bottom"},
    {:docker_reviewer, :approve, "clean", nil, "right", "left"},
    {:approve, :done, "accepted", nil, "right", "left"},
    {:approve, :coder, "continue", nil, "top", "top"}
  ]

  defp seed_default do
    workflow = uuid()

    execute_sql("INSERT INTO workflows (id, name, position) VALUES ($1, 'Default', 0)", [workflow])

    nodes = Map.new(@nodes, fn {key, _node} -> {key, uuid()} end)

    for {key, {kind, label, role, column, x, start}} <- @nodes do
      execute_sql(
        """
        INSERT INTO workflow_nodes (id, workflow_id, kind, label, agent_role, column_status, x, y, start)
        VALUES ($1, $2, $3, $4, $5, $6, $7, 0, $8)
        """,
        [nodes[key], workflow, kind, label, role, column, x, start]
      )
    end

    edges =
      for {from, to, condition, iterations, from_port, to_port} <- @edges, into: %{} do
        id = uuid()

        execute_sql(
          """
          INSERT INTO workflow_edges (id, workflow_id, from_node_id, to_node_id, condition, iterations, from_port, to_port)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
          """,
          [id, workflow, nodes[from], nodes[to], condition, iterations, from_port, to_port]
        )

        {{from, to}, id}
      end

    %{id: workflow, nodes: nodes, edges: edges}
  end

  # Every task runs the default from the block its stage and status say it is on; a task
  # sent back to the coder keeps its fix rounds on the findings arrow.
  defp backfill(workflow) do
    execute_sql("UPDATE tasks SET workflow_id = $1", [workflow.id])

    [
      {:approve_plan,
       "stage = 'planning' AND status = 'await_human_supervision' AND plan IS NOT NULL"},
      {:planner, "stage = 'planning' AND current_node_id IS NULL"},
      {:coder, "stage = 'coding'"},
      {:reviewer, "stage = 'code_review'"},
      {:docker_reviewer, "stage = 'qa'"},
      {:approve,
       "stage IS NULL AND status = 'await_human_supervision' AND worktree_branch IS NOT NULL"}
    ]
    |> Enum.each(fn {node, condition} ->
      execute_sql("UPDATE tasks SET current_node_id = $1 WHERE #{condition}", [
        workflow.nodes[node]
      ])
    end)

    execute_sql(
      "UPDATE tasks SET edge_counts = jsonb_build_object($1::text, review_round) WHERE review_round > 0",
      [Ecto.UUID.cast!(workflow.edges[{:docker_reviewer, :coder}])]
    )
  end

  defp uuid, do: Ecto.UUID.dump!(Ecto.UUID.generate())

  defp execute_sql(sql, params), do: repo().query!(sql, params)

  def down do
    alter table(:tasks) do
      remove :current_node_id
      remove :workflow_id
      remove :node_counts
      remove :edge_counts
    end

    drop table(:workflow_edges)
    drop table(:workflow_nodes)
    drop table(:workflows)
  end
end
