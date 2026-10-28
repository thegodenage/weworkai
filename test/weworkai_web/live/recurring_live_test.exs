defmodule WeworkaiWeb.RecurringLiveTest do
  use WeworkaiWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Weworkai.{Recurring, Workflows}

  test "the sidebar leads to it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, ~s|nav a[href="/recurring"]|, "Recurring")
  end

  test "a weekly cron is added, paused and deleted", %{conn: conn} do
    workflow = Workflows.default_workflow!()
    {:ok, view, _html} = live(conn, ~p"/recurring")
    assert has_element?(view, "#crons-empty")

    view |> element("#new-cron") |> render_click()
    assert_patch(view, ~p"/recurring/new")

    view
    |> form("#cron-form", form: %{name: "Daily GitLab digest", days: [""]})
    |> render_change()

    assert has_element?(view, "#cron-days-errors")

    view
    |> form("#cron-form",
      form: %{
        name: "Daily GitLab digest",
        workflow_id: workflow.id,
        days: ["", "1", "3"],
        at: "09:00",
        timezone: "Europe/Warsaw",
        description: "Fetch the newest GitLab interactions"
      }
    )
    |> render_submit()

    assert_patch(view, ~p"/recurring")
    [cron] = Recurring.list_crons!()
    assert %{mode: :weekly, days: [1, 3]} = cron
    assert has_element?(view, "#cron-#{cron.id}-when", "Mon, Wed at 09:00 (Europe/Warsaw)")
    assert has_element?(view, "#cron-#{cron.id}-workflow", workflow.name)
    assert has_element?(view, "#cron-#{cron.id}-next")

    view |> element("#cron-#{cron.id}-toggle") |> render_click()
    assert has_element?(view, "#cron-#{cron.id}-paused")
    refute Recurring.get_cron!(cron.id).enabled

    view |> element("#cron-#{cron.id}-delete") |> render_click()
    assert has_element?(view, "#crons-empty")
    assert Recurring.list_crons!() == []
  end

  test "a cron on an expression previews its next runs; a bad one is refused", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/recurring/new")
    refute has_element?(view, "#cron-expression")

    view |> form("#cron-form", form: %{mode: "expression"}) |> render_change()
    assert has_element?(view, "#cron-expression")
    refute has_element?(view, "#cron-days")

    assert view
           |> form("#cron-form", form: %{name: "Bad", mode: "expression", expression: "9am"})
           |> render_submit() =~ "is not a valid cron expression"

    view
    |> form("#cron-form",
      form: %{
        name: "Half-hourly inbox",
        mode: "expression",
        expression: "*/30 8-18 * * *",
        timezone: "Europe/Warsaw"
      }
    )
    |> render_change()

    assert has_element?(view, "#cron-upcoming span")

    view |> form("#cron-form") |> render_submit()
    assert_patch(view, ~p"/recurring")
    [cron] = Recurring.list_crons!()
    assert %{mode: :expression, expression: "*/30 8-18 * * *"} = cron
    assert has_element?(view, "#cron-#{cron.id}-when", "*/30 8-18 * * * (Europe/Warsaw)")
  end

  test "a slot missed in an outage is shown after the catch-up run", %{conn: conn} do
    cron =
      Recurring.create_cron!(%{
        name: "Hourly",
        workflow_id: Workflows.default_workflow!().id,
        mode: :expression,
        expression: "0 * * * *"
      })

    Recurring.claim_cron!(cron, %{next_run_at: ~U[2026-11-02 08:00:00Z]})
    :ok = Weworkai.Recurring.Runner.start_due(~U[2026-11-02 11:10:00Z])
    :ok = Weworkai.Recurring.Runner.start_due(~U[2026-11-02 11:10:01Z])

    {:ok, view, _html} = live(conn, ~p"/recurring")
    assert has_element?(view, "#cron-#{cron.id}-skipped")
  end

  test "a cron fired or deleted elsewhere shows so", %{conn: conn} do
    cron =
      Recurring.create_cron!(%{
        name: "Hourly",
        workflow_id: Workflows.default_workflow!().id,
        mode: :expression,
        expression: "0 * * * *"
      })

    {:ok, view, _html} = live(conn, ~p"/recurring")
    assert has_element?(view, "#cron-#{cron.id}-tasks", "0 tasks")

    :ok = Weworkai.Recurring.Runner.start_due(DateTime.add(cron.next_run_at, 1, :minute))
    assert has_element?(view, "#cron-#{cron.id}-tasks", "1 task")
    assert has_element?(view, "#cron-#{cron.id}-last-task")

    # Its row is still here when the person clicks; the cron isn't.
    stale = element(view, "#cron-#{cron.id}-run")
    Weworkai.Repo.query!("DELETE FROM crons WHERE id = $1", [Ecto.UUID.dump!(cron.id)])
    render_click(stale)
    assert render(view) =~ "Cron not found."
  end

  test "@reboot is refused, not crashed on", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/recurring/new")
    view |> form("#cron-form", form: %{mode: "expression"}) |> render_change()

    assert view
           |> form("#cron-form", form: %{name: "Boot", mode: "expression", expression: "@reboot"})
           |> render_change() =~ "@reboot is not supported"
  end

  test "an unknown time zone is refused", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/recurring/new")

    assert view
           |> form("#cron-form", form: %{name: "Digest", timezone: "Mars/Olympus"})
           |> render_submit() =~ "is not a known time zone"
  end
end
