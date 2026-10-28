defmodule Weworkai.Recurring.Cron.Validations.Timezone do
  @moduledoc "A cron's time zone is one the time zone database knows, e.g. `Europe/Warsaw`."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :timezone) do
      # allow_nil? false reports it.
      nil ->
        :ok

      timezone ->
        case DateTime.now(timezone) do
          {:ok, _now} -> :ok
          {:error, _reason} -> {:error, field: :timezone, message: "is not a known time zone"}
        end
    end
  end
end
