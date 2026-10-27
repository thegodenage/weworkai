defmodule Weworkai.Repo.Migrations.WorkflowVersions do
  @moduledoc """
  Workflow versions (docs/workflows.md, "Versions"): every workflow's graph as it is now
  becomes its version 1 (its `version` restarts there), and every task is pinned to it.

  Generated with `mix ash_postgres.generate_migrations`, then the backfill added.
  """

  use Ecto.Migration

  def up do
    alter table(:workflows) do
      modify :version, :bigint, default: 1
    end

    execute "UPDATE workflows SET version = 1"

    create table(:workflow_versions, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :number, :bigint, null: false
      add :graph, :map, null: false
      add :problem_count, :bigint, null: false, default: 0

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :workflow_id,
          references(:workflows,
            column: :id,
            name: "workflow_versions_workflow_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false
    end

    create unique_index(:workflow_versions, [:workflow_id, :number],
             name: "workflow_versions_number_index"
           )

    # The graph in the editor's params shape (Workflows.params/1).
    execute """
    INSERT INTO workflow_versions (workflow_id, number, graph, problem_count)
    SELECT w.id, 1,
      jsonb_build_object(
        'nodes', coalesce((
          SELECT jsonb_agg(jsonb_build_object(
            'id', n.id, 'kind', n.kind, 'label', n.label, 'employee_id', n.employee_id,
            'agent_role', n.agent_role, 'column_status', n.column_status,
            'group_id', n.group_id, 'x', n.x, 'y', n.y, 'width', n.width,
            'height', n.height, 'start', n.start, 'color', n.color, 'prompt', n.prompt
          ))
          FROM workflow_nodes n WHERE n.workflow_id = w.id
        ), '[]'),
        'edges', coalesce((
          SELECT jsonb_agg(jsonb_build_object(
            'id', e.id, 'condition', e.condition, 'iterations', e.iterations,
            'from_port', e.from_port, 'to_port', e.to_port, 'pinned', e.pinned,
            'from', e.from_node_id, 'to', e.to_node_id
          ))
          FROM workflow_edges e WHERE e.workflow_id = w.id
        ), '[]')
      ),
      w.problem_count
    FROM workflows w
    """

    alter table(:tasks) do
      add :workflow_version, :bigint, null: false, default: 1
    end

    alter table(:tasks) do
      modify :workflow_version, :bigint, default: nil
    end
  end

  def down do
    alter table(:workflows) do
      modify :version, :bigint, default: 0
    end

    drop constraint(:workflow_versions, "workflow_versions_workflow_id_fkey")

    drop_if_exists unique_index(:workflow_versions, [:workflow_id, :number],
                     name: "workflow_versions_number_index"
                   )

    drop table(:workflow_versions)

    alter table(:tasks) do
      remove :workflow_version
    end
  end
end
