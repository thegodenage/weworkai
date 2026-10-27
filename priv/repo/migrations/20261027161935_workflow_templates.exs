defmodule Weworkai.Repo.Migrations.WorkflowTemplates do
  @moduledoc """
  Example workflows "New from template" copies (docs/workflows.md, "Templates"). The column
  was generated with `mix ash_postgres.generate_migrations`; the rest marks the seeded
  default as a template and seeds "Double review" beside it, at the end of the list so the
  default stays the default. Its ids are fixed and every insert skips rows that exist, so
  running it again changes nothing.
  """

  use Ecto.Migration

  @workflow "d0ab1e00-5e7e-4000-8000-000000000000"

  # Like the default's two rows: planning and coding above; below, right to left, the two
  # reviewers as one group the task goes through twice in a row while it is clean, then
  # approval and done. The arrows back to the coder meet on its bottom dot, as in the default.
  @nodes [
    planner: {"agent", "Planner", "planner", nil, {400, 60}, true},
    approve_plan: {"human", "Approve plan", nil, nil, {720, 60}, false},
    coder: {"agent", "Coder", "coder", nil, {1040, 60}, false},
    review: {"group", "Full review", nil, nil, {640, 280, 620, 160}, false},
    reviewer: {"agent", "Reviewer", "reviewer", nil, {1000, 340}, false},
    docker_reviewer: {"agent", "Docker reviewer", "qa", nil, {680, 340}, false},
    approve: {"human", "Approve", nil, nil, {320, 340}, false},
    done: {"column", "Done", nil, "done", {0, 340}, false}
  ]

  @members %{reviewer: :review, docker_reviewer: :review}

  @edges [
    {:planner, :approve_plan, "plan_ready", nil, "right", "left"},
    {:approve_plan, :coder, "approved", nil, "right", "left"},
    {:coder, :review, "done", nil, "right", "right"},
    {:reviewer, :docker_reviewer, nil, nil, "left", "right"},
    {:review, :review, "clean", 2, "bottom", "bottom"},
    {:review, :coder, "findings", 3, "top", "bottom"},
    {:review, :approve, "clean", nil, "left", "right"},
    {:approve, :done, "accepted", nil, "left", "right"},
    {:approve, :coder, "continue", nil, "top", "bottom"}
  ]

  def up do
    alter table(:workflows) do
      add :template, :text
    end

    flush()

    execute_sql("""
    UPDATE workflows SET template = 'default'
    WHERE id = (SELECT id FROM workflows WHERE name = 'Default' ORDER BY inserted_at LIMIT 1)
    """)

    seed_double_review()
  end

  defp seed_double_review do
    execute_sql(
      """
      INSERT INTO workflows (id, name, position, template)
      SELECT $1, 'Double review', coalesce(max(position), -1) + 1, 'double_review' FROM workflows
      ON CONFLICT (id) DO NOTHING
      """,
      [uuid(@workflow)]
    )

    # Groups first, for the foreign key from the blocks inside them.
    {groups, blocks} = Enum.split_with(@nodes, fn {_key, node} -> elem(node, 0) == "group" end)

    for {key, {kind, label, role, column, geometry, start}} <- groups ++ blocks do
      {x, y, width, height} = box(geometry)

      execute_sql(
        """
        INSERT INTO workflow_nodes
          (id, workflow_id, kind, label, agent_role, column_status, x, y, width, height, start, group_id, color)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        ON CONFLICT (id) DO NOTHING
        """,
        [
          node_id(key),
          uuid(@workflow),
          kind,
          label,
          role,
          column,
          x,
          y,
          width,
          height,
          start,
          @members[key] && node_id(@members[key]),
          if(kind == "group", do: "blue")
        ]
      )
    end

    for {{from, to, condition, iterations, from_port, to_port}, index} <- Enum.with_index(@edges) do
      execute_sql(
        """
        INSERT INTO workflow_edges
          (id, workflow_id, from_node_id, to_node_id, condition, iterations, from_port, to_port)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        ON CONFLICT (id) DO NOTHING
        """,
        [
          id(0x100 + index),
          uuid(@workflow),
          node_id(from),
          node_id(to),
          condition,
          iterations,
          from_port,
          to_port
        ]
      )
    end
  end

  defp box({x, y}), do: {x, y, nil, nil}
  defp box(box), do: box

  # Blocks are numbered 1.. in @nodes' order, arrows 0x100.. in @edges'.
  defp node_id(key), do: id(1 + Enum.find_index(@nodes, fn {node, _} -> node == key end))

  defp id(number) do
    suffix = number |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")
    uuid("d0ab1e00-5e7e-4000-8000-" <> suffix)
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)

  defp execute_sql(sql, params \\ []), do: repo().query!(sql, params)

  def down do
    execute_sql(
      "DELETE FROM workflows WHERE id = $1 AND NOT EXISTS (SELECT 1 FROM tasks WHERE workflow_id = $1)",
      [uuid(@workflow)]
    )

    alter table(:workflows) do
      remove :template
    end
  end
end
