defmodule Weworkai.Agents.Agent.Validations.OfferedByConnector do
  @moduledoc """
  The chosen model and effort must be on the linked connector's current list, fetched
  fresh, so a stale form cannot store something the connector no longer offers.
  """
  use Ash.Resource.Validation

  alias Weworkai.Connectors

  @impl true
  def validate(changeset, _opts, _context) do
    model = Ash.Changeset.get_attribute(changeset, :model)
    effort = Ash.Changeset.get_attribute(changeset, :effort)

    case Ash.load!(changeset.data, connector_link: :connector) do
      %{connector_link: %{connector: connector}} ->
        check_offered(Connectors.model_options(connector), connector, model, effort)

      %{connector_link: nil} ->
        {:error, field: :model, message: "needs a linked connector"}
    end
  end

  defp check_offered({:error, message}, _connector, _model, _effort) do
    {:error, field: :model, message: message}
  end

  defp check_offered({:ok, options}, connector, model, effort) do
    cond do
      model not in Enum.map(options.models, & &1.id) ->
        {:error, field: :model, message: "is not offered by #{connector.name}"}

      effort != nil and effort not in options.efforts ->
        {:error, field: :effort, message: "is not offered by #{connector.name}"}

      true ->
        :ok
    end
  end
end
