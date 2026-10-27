defmodule WeworkaiWeb.AttachmentControllerTest do
  use WeworkaiWeb.ConnCase, async: true

  alias Weworkai.Board

  setup do
    %{task: Board.create_task!(%{title: "Files"})}
  end

  test "an image opens in the browser", %{conn: conn, task: task} do
    attachment = Board.attach_file!(%{task_id: task.id, file_name: "shot.png", content: "png"})
    conn = get(conn, ~p"/attachments/#{attachment.id}")

    assert response(conn, 200) == "png"
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="shot.png")]
  end

  test "anything else downloads, so it never runs as a page of the app", %{conn: conn, task: task} do
    attachment =
      Board.attach_file!(%{
        task_id: task.id,
        file_name: "page.html",
        content: "<script></script>"
      })

    conn = get(conn, ~p"/attachments/#{attachment.id}")

    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="page.html")]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "an unknown attachment is not found", %{conn: conn} do
    assert conn |> get(~p"/attachments/#{Ecto.UUID.generate()}") |> response(404)
    assert conn |> get("/attachments/nope") |> response(404)
  end
end
