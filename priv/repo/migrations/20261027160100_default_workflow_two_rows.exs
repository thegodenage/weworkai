defmodule Weworkai.Repo.Migrations.DefaultWorkflowTwoRows do
  @moduledoc """
  The seeded default workflow ran in one row 2140px wide, which the editor could only fit
  at about a third of its size. Lays the untouched seed (and untouched copies of it) out
  in two rows, planning and coding above, review and approval below: geometry and arrow
  ports only, ids kept.
  """
  use Ecto.Migration

  @two_rows %{
    "Planner" => {0, 0},
    "Approve plan" => {320, 0},
    "Coder" => {640, 0},
    "Reviewer" => {960, 0},
    "Docker reviewer" => {960, 260},
    "Approve" => {480, 260},
    "Done" => {160, 260}
  }

  @one_row %{
    "Planner" => {0, 0},
    "Approve plan" => {320, 0},
    "Coder" => {640, 0},
    "Reviewer" => {960, 0},
    "Docker reviewer" => {1280, 0},
    "Approve" => {1600, 0},
    "Done" => {1920, 0}
  }

  # {from, to, condition} => {two rows' ports, one row's ports}
  @ports %{
    {"Reviewer", "Docker reviewer", nil} => {{"right", "right"}, {"right", "left"}},
    {"Docker reviewer", "Coder", "findings"} => {{"top", "bottom"}, {"bottom", "bottom"}},
    {"Docker reviewer", "Approve", "clean"} => {{"left", "right"}, {"right", "left"}},
    {"Approve", "Done", "accepted"} => {{"left", "right"}, {"right", "left"}},
    {"Approve", "Coder", "continue"} => {{"top", "bottom"}, {"top", "top"}}
  }

  def up, do: lay_out(@one_row, @two_rows, &elem(&1, 0))
  def down, do: lay_out(@two_rows, @one_row, &elem(&1, 1))

  defp lay_out(from, to, ports) do
    workflows = untouched(from)

    for {label, {x, y}} <- to do
      execute_sql(
        "UPDATE workflow_nodes SET x = $1, y = $2 WHERE label = $3 AND workflow_id = ANY($4)",
        [x, y, label, workflows]
      )
    end

    for {{source, target, condition}, both} <- @ports, {from_port, to_port} = ports.(both) do
      execute_sql(
        """
        UPDATE workflow_edges SET from_port = $1, to_port = $2
        FROM workflow_nodes source, workflow_nodes target
        WHERE workflow_edges.from_node_id = source.id AND workflow_edges.to_node_id = target.id
          AND source.label = $3 AND target.label = $4
          AND workflow_edges.condition IS NOT DISTINCT FROM $5
          AND workflow_edges.workflow_id = ANY($6)
        """,
        [from_port, to_port, source, target, condition, workflows]
      )
    end
  end

  # Workflows whose seven blocks still sit exactly where `layout` put them.
  defp untouched(layout) do
    {labels, xs, ys} =
      Enum.reduce(layout, {[], [], []}, fn {label, {x, y}}, {labels, xs, ys} ->
        {[label | labels], [x | xs], [y | ys]}
      end)

    %{rows: rows} =
      repo().query!(
        """
        SELECT workflow_id FROM workflow_nodes
        LEFT JOIN unnest($1::text[], $2::bigint[], $3::bigint[]) AS seed(label, x, y)
          ON seed.label = workflow_nodes.label AND seed.x = workflow_nodes.x
            AND seed.y = workflow_nodes.y AND workflow_nodes.group_id IS NULL
        GROUP BY workflow_id
        HAVING count(*) = 7 AND count(seed.label) = 7
        """,
        [labels, xs, ys]
      )

    List.flatten(rows)
  end

  defp execute_sql(sql, params), do: repo().query!(sql, params)
end
