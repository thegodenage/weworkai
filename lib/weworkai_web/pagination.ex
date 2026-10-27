defmodule WeworkaiWeb.Pagination do
  @moduledoc """
  Offset pagination for list pages: parses the `page` URL param and builds Ash page options.
  """

  def page_number(value) do
    case Integer.parse(value || "") do
      {number, ""} when number > 0 -> number
      _ -> 1
    end
  end

  def page_options(number, size), do: [offset: (number - 1) * size, limit: size, count: true]

  def page_count(total, size), do: max(div(total + size - 1, size), 1)
end
