defmodule WeworkaiWeb.WorkflowsLiveTest do
  use WeworkaiWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Weworkai.{Board, Workflows}

  defp row(workflow), do: "#workflows-#{workflow.id}"

  test "lists the default workflow first, with its blocks and the tasks using it", %{conn: conn} do
    default = Workflows.default_workflow!()
    Board.create_task!(%{title: "Uses it"})
    {:ok, view, _html} = live(conn, ~p"/workflows")

    assert has_element?(view, "#workflow-#{default.id}-default")
    assert has_element?(view, "#workflow-#{default.id}-blocks", "7 blocks")
    assert has_element?(view, "#workflow-#{default.id}-tasks", "1 task")
    assert has_element?(view, "#workflow-#{default.id}-up[disabled]")
  end

  test "a workflow saved with problems is marked in the list and the task form", %{conn: conn} do
    {:ok, draft} = Workflows.create_workflow("Half drawn", nil, %{empty: true})
    {:ok, view, _html} = live(conn, ~p"/workflows")
    assert has_element?(view, "#workflow-#{draft.id}-problems", "1 problem")
    refute has_element?(view, "#workflow-#{Workflows.default_workflow!().id}-problems")

    {:ok, board, _html} = live(conn, ~p"/tasks/new")

    assert has_element?(
             board,
             "#task-form option[value='#{draft.id}']",
             "Half drawn (has problems)"
           )
  end

  test "the sidebar leads to it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, ~s|nav a[href="/workflows"]|, "Workflows")
  end

  test "a new workflow starts as a copy; it can be renamed and moved first", %{conn: conn} do
    default = Workflows.default_workflow!()
    {:ok, view, _html} = live(conn, ~p"/workflows")

    view |> element("#new-workflow") |> render_click()
    assert_patch(view, ~p"/workflows/new")
    assert view |> form("#workflow-form", form: %{name: " "}) |> render_submit() =~ "is required"

    assert {:error, {:live_redirect, %{to: editor}}} =
             view
             |> form("#workflow-form", form: %{name: "Quick fixes", source_id: default.id})
             |> render_submit()

    copy = Enum.find(Workflows.list_workflows!(), &(&1.name == "Quick fixes"))
    assert editor == ~p"/workflows/#{copy.id}"
    {:ok, view, _html} = live(conn, ~p"/workflows")
    assert has_element?(view, row(copy), "7 blocks")
    refute has_element?(view, "#workflow-#{copy.id}-default")

    view |> element("#workflow-#{copy.id}-rename") |> render_click()
    view |> form("#workflow-form", form: %{name: "Hotfixes"}) |> render_submit()
    assert has_element?(view, row(copy), "Hotfixes")

    # Behind the default and the "Double review" template.
    view |> element("#workflow-#{copy.id}-up") |> render_click()
    refute has_element?(view, "#workflow-#{copy.id}-default")
    view |> element("#workflow-#{copy.id}-up") |> render_click()
    assert has_element?(view, "#workflow-#{copy.id}-default")
    assert Workflows.default_workflow!().id == copy.id
    assert Board.create_task!(%{title: "New"}).workflow_id == copy.id
  end

  test "a workflow tasks use can't be deleted; an unused one can", %{conn: conn} do
    default = Workflows.default_workflow!()
    copy = Workflows.create_workflow!("Spare")
    task = Board.create_task!(%{title: "Uses it", workflow_id: copy.id})
    {:ok, view, _html} = live(conn, ~p"/workflows")

    assert view |> element("#workflow-#{copy.id}-delete") |> render_click() =~
             "1 task still use this workflow"

    Board.destroy_task!(task)
    view |> element("#workflow-#{copy.id}-delete") |> render_click()
    refute has_element?(view, row(copy))

    # A template is a workflow like any other; only the last one stays.
    [_default, double_review] = Workflows.list_templates!()
    view |> element("#workflow-#{double_review.id}-delete") |> render_click()
    refute has_element?(view, row(double_review))

    assert view |> element("#workflow-#{default.id}-delete") |> render_click() =~
             "the last workflow can&#39;t be deleted"
  end

  test "a new workflow starts empty unless it copies one, and opens in the editor",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workflows/new")
    assert has_element?(view, "#workflow-form option:first-child[value='']", "An empty canvas")
    refute has_element?(view, "#workflow-form option[selected]")

    assert {:error, {:live_redirect, %{to: editor}}} =
             view |> form("#workflow-form", form: %{name: "Blank"}) |> render_submit()

    blank = Enum.find(Workflows.list_workflows!(), &(&1.name == "Blank"))
    assert editor == ~p"/workflows/#{blank.id}"
    assert blank.block_count == 0
  end

  test "the seeded templates are marked in the list", %{conn: conn} do
    assert [%{template: :default} = default, %{template: :double_review} = double_review] =
             Workflows.list_templates!()

    assert default.id == Workflows.default_workflow!().id
    {:ok, view, _html} = live(conn, ~p"/workflows")
    assert has_element?(view, "#workflow-#{default.id}-template")
    assert has_element?(view, "#workflow-#{double_review.id}-template")
    assert has_element?(view, "#workflow-#{double_review.id}-blocks", "7 blocks")
  end

  test "new from template copies the chosen one, or starts blank, and opens it in the editor",
       %{conn: conn} do
    [_default, double_review] = Workflows.list_templates!()
    {:ok, view, _html} = live(conn, ~p"/workflows")

    view |> element("#new-from-template") |> render_click()
    assert_patch(view, ~p"/workflows/from-template")
    assert has_element?(view, "#template-blank-input[checked]")
    assert has_element?(view, "#template-default")
    assert has_element?(view, "#template-double_review", "7 blocks")

    assert {:error, {:live_redirect, %{to: editor}}} =
             view
             |> form("#workflow-form", form: %{name: "Twice", source_id: double_review.id})
             |> render_submit()

    copy = Enum.find(Workflows.list_workflows!(), &(&1.name == "Twice"))
    assert editor == ~p"/workflows/#{copy.id}"
    assert %{block_count: 7, problem_count: 0, template: nil} = copy
    refute MapSet.intersection(ids(copy), ids(double_review)) |> Enum.any?()

    {:ok, view, _html} = live(conn, ~p"/workflows/from-template")

    assert {:error, {:live_redirect, %{to: _editor}}} =
             view |> form("#workflow-form", form: %{name: "Blank slate"}) |> render_submit()

    assert %{block_count: 0} =
             Enum.find(Workflows.list_workflows!(), &(&1.name == "Blank slate"))
  end

  defp ids(workflow),
    do: workflow.id |> Workflows.graph!() |> Map.fetch!(:nodes) |> Map.keys() |> MapSet.new()
end
