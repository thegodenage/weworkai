defmodule WeworkaiWeb.E2EController do
  @moduledoc "Lets the e2e run start from a fresh database (`Weworkai.E2E`); 404 elsewhere."
  use WeworkaiWeb, :controller

  alias Weworkai.E2E

  def reset(conn, _params) do
    if E2E.enabled?() do
      E2E.reset!()
      send_resp(conn, 204, "")
    else
      send_resp(conn, 404, "")
    end
  end
end
