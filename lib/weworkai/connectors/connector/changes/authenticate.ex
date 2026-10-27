defmodule Weworkai.Connectors.Connector.Changes.Authenticate do
  @moduledoc """
  Asks the provider's adapter to verify access, then records the outcome: on success the
  auth metadata is stored (replacing any earlier one); on failure it is dropped, since it
  no longer describes a working session.
  """
  use Ash.Resource.Change

  alias Weworkai.Connectors.Connector.Provider

  @impl true
  def change(changeset, _opts, _context) do
    # The adapter may call out over the network, so keep it outside the DB transaction.
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      adapter = Provider.adapter(changeset.data.provider)

      case adapter.authenticate() do
        {:ok, metadata} ->
          auth = %{
            method: adapter.auth_method(),
            metadata: metadata,
            verified_at: DateTime.utc_now()
          }

          changeset
          |> Ash.Changeset.force_change_attributes(status: :connected, status_message: nil)
          |> Ash.Changeset.manage_relationship(:auth, auth,
            on_no_match: {:create, :record},
            on_missing: :ignore
          )

        {:error, message} ->
          changeset
          |> Ash.Changeset.force_change_attributes(status: :error, status_message: message)
          |> Ash.Changeset.manage_relationship(:auth, nil, on_missing: :destroy)
      end
    end)
  end
end
