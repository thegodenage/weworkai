defmodule Weworkai.E2E do
  @moduledoc """
  Puts the e2e instance's database back to a fresh install before a Playwright run
  (e2e/global-setup.js, through `WeworkaiWeb.E2EController`): every row goes, then the
  template workflows come back exactly as the migrations seed them, from a snapshot
  (`priv/e2e/templates.json`), so a spec that edits a template never leaks into the next
  run. Only ever on a database named `*_e2e` (docker-compose.yml's web-e2e), so the dev
  and test databases are out of its reach.

  `Weworkai.E2ETest` checks the snapshot against the migrations on the test database;
  after a migration changes a template, rewrite it with
  `WRITE_E2E_SNAPSHOT=1 mix test test/weworkai/e2e_test.exs`.
  """
  alias Weworkai.{Repo, Workflows}

  # Parents before children: the rows' foreign keys hold as they go in.
  @tables [{"workflows", "workflows"}, {"workflow_nodes", "nodes"}, {"workflow_edges", "edges"}]

  def enabled?, do: String.ends_with?(Repo.config()[:database], "_e2e")

  def snapshot_path, do: Application.app_dir(:weworkai, "priv/e2e/templates.json")

  def reset! do
    true = enabled?()
    seed = snapshot_path() |> File.read!() |> JSON.decode!()

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!("TRUNCATE #{Enum.join(tables(), ", ")} CASCADE")

        for {table, key} <- @tables do
          Repo.query!(
            "INSERT INTO #{table} SELECT * FROM jsonb_populate_recordset(NULL::#{table}, $1::jsonb)",
            [seed[key]]
          )
        end

        # Version ids and times are no template's: recorded afresh, from the graphs restored.
        Enum.each(Workflows.list_workflows!(), &Workflows.record_version!/1)
      end)

    :ok
  end

  @doc "The template workflows as stored now, with their blocks and arrows: what `reset!/0` restores."
  def snapshot do
    templates = "SELECT id FROM workflows WHERE template IS NOT NULL"

    %{
      "workflows" => rows("SELECT * FROM workflows WHERE template IS NOT NULL ORDER BY position"),
      "nodes" =>
        rows("SELECT * FROM workflow_nodes WHERE workflow_id IN (#{templates}) ORDER BY id"),
      "edges" =>
        rows("SELECT * FROM workflow_edges WHERE workflow_id IN (#{templates}) ORDER BY id")
    }
  end

  defp rows(query) do
    %{rows: [[rows]]} =
      Repo.query!("SELECT coalesce(jsonb_agg(row_to_json(row)), '[]') FROM (#{query}) row")

    rows
  end

  defp tables do
    Repo.query!("""
    SELECT quote_ident(tablename) FROM pg_tables
    WHERE schemaname = 'public' AND tablename <> 'schema_migrations'
    """).rows
    |> List.flatten()
  end
end
