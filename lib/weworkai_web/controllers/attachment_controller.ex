defmodule WeworkaiWeb.AttachmentController do
  use WeworkaiWeb, :controller

  alias Weworkai.Board
  alias Weworkai.Board.TaskAttachment

  # Only raster images open in the browser; anything else (HTML and SVG included) downloads,
  # so an uploaded file never runs as a page of this app.
  def show(conn, %{"id" => id}) do
    case Board.get_attachment_file(id) do
      {:ok, attachment} ->
        disposition = if TaskAttachment.image?(attachment.name), do: "inline", else: "attachment"

        conn
        |> put_resp_content_type(MIME.from_path(attachment.name), nil)
        |> put_resp_header(
          "content-disposition",
          ~s(#{disposition}; filename="#{attachment.name}")
        )
        |> send_resp(200, attachment.content)

      {:error, _not_found} ->
        send_resp(conn, 404, "Not found")
    end
  end
end
