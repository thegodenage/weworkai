defmodule Weworkai.Board.Task.Validations.CoderEmployee do
  @moduledoc """
  An approved plan goes to an agent employee whose agent is a coder that can run (model and
  connector set); any other would only fail to start.
  """
  use Ash.Resource.Validation

  alias Weworkai.{Agents, Organization}
  alias Weworkai.Agents.Errors.NotRunnable

  @impl true
  def validate(changeset, _opts, _context) do
    employee_id = Ash.Changeset.get_argument(changeset, :coder_employee_id)

    case Organization.get_employee(employee_id, load: [agent: :connector_link]) do
      {:ok, %{agent: %{role: :coder} = coder} = employee} -> runnable(employee, coder)
      _other -> {:error, field: :coder_employee_id, message: "must be a coder agent that can run"}
    end
  end

  defp runnable(employee, coder) do
    case Agents.missing_setup(coder) do
      nil -> :ok
      missing -> {:error, NotRunnable.exception(name: employee.name, missing: missing)}
    end
  end
end
