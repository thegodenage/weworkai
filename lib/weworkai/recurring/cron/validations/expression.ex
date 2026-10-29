defmodule Weworkai.Recurring.Cron.Validations.Expression do
  @moduledoc """
  A cron in expression mode has an expression that parses and matches some date
  (`Runner.check_expression/1`). How often it runs is up to the person: runs close
  together are grouped on the board, not refused.
  """
  use Ash.Resource.Validation

  alias Weworkai.Recurring.Runner

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :mode) do
      :expression ->
        case Ash.Changeset.get_attribute(changeset, :expression) do
          nil -> {:error, field: :expression, message: "is required"}
          expression -> check(expression)
        end

      _weekly ->
        :ok
    end
  end

  defp check(expression) do
    case Runner.check_expression(expression) do
      :ok -> :ok
      {:error, message} -> {:error, field: :expression, message: message}
    end
  end
end
