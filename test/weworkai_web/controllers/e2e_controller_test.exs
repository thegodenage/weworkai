defmodule WeworkaiWeb.E2EControllerTest do
  use WeworkaiWeb.ConnCase

  alias Weworkai.Board

  test "is not there outside the e2e instance", %{conn: conn} do
    Board.create_task!(%{title: "Kept"})
    assert conn |> post(~p"/e2e/reset") |> response(404)
    assert [%{title: "Kept"}] = Board.list_tasks!()
  end
end
