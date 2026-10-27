defmodule Weworkai.E2ETest do
  use Weworkai.DataCase, async: true

  alias Weworkai.E2E

  # The default's ids are random per database, and timestamps whenever it was migrated: rows
  # compare by what they name instead (a template, a block's label, an arrow's ends).
  defp comparable(%{"workflows" => workflows, "nodes" => nodes, "edges" => edges}) do
    names = Map.new(workflows, &{&1["id"], &1["template"]})

    names =
      Map.merge(names, Map.new(nodes, &{&1["id"], "#{names[&1["workflow_id"]]}/#{&1["label"]}"}))

    names =
      Map.merge(
        names,
        Map.new(
          edges,
          &{&1["id"],
           "#{names[&1["from_node_id"]]} → #{names[&1["to_node_id"]]} #{&1["condition"]}"}
        )
      )

    for rows <- [workflows, nodes, edges] do
      rows
      |> Enum.map(fn row ->
        row
        |> Map.drop(["inserted_at", "updated_at"])
        |> Map.new(fn {key, value} -> {key, Map.get(names, value, value)} end)
      end)
      |> Enum.sort_by(& &1["id"])
    end
  end

  test "the e2e reset's template snapshot is what the migrations seed" do
    if System.get_env("WRITE_E2E_SNAPSHOT"),
      do: File.write!(E2E.snapshot_path(), JSON.encode!(E2E.snapshot()))

    stored = E2E.snapshot_path() |> File.read!() |> JSON.decode!()
    assert comparable(stored) == comparable(E2E.snapshot())
  end
end
