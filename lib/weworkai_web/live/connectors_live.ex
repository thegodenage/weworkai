defmodule WeworkaiWeb.ConnectorsLive do
  use WeworkaiWeb, :live_view

  alias Weworkai.Connectors
  alias Weworkai.Connectors.Connector.{Provider, Status}
  alias WeworkaiWeb.Pagination

  @page_size 20

  @tones %{disconnected: "slate", connected: "green", error: "red"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Connectors")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> assign(filters: filters(params), selected: selected(params["selected"]))
      |> then(&load_page(&1, page_number(&1, params["page"])))

    if socket.assigns.page_number > socket.assigns.page_count do
      {:noreply,
       push_patch(socket, to: list_path(socket.assigns.filters, socket.assigns.page_count))}
    else
      {:noreply, apply_action(socket, socket.assigns.live_action, params)}
    end
  end

  # URL params are untrusted: unknown enum values and blank search mean "no filter".
  defp filters(params) do
    %{
      search: blank_to_nil(params["search"]),
      provider: enum_value(Provider, params["provider"]),
      status: enum_value(Status, params["status"])
    }
  end

  defp selected(value) do
    with {:ok, id} <- Ecto.UUID.cast(value || ""),
         {:ok, connector} <- Connectors.get_connector(id) do
      connector
    else
      _ -> nil
    end
  end

  # A link to a selected connector carries no page, so open the page that contains it.
  defp page_number(%{assigns: %{selected: %{} = connector, filters: filters}}, nil) do
    div(Connectors.position(connector, filters), @page_size) + 1
  end

  defp page_number(_socket, page), do: Pagination.page_number(page)

  defp blank_to_nil(value) do
    case String.trim(value || "") do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp enum_value(enum, value) do
    case enum.match(value || "") do
      {:ok, matched} -> matched
      :error -> nil
    end
  end

  defp load_page(socket, number) do
    page =
      Connectors.list_connectors!(socket.assigns.filters,
        page: Pagination.page_options(number, @page_size)
      )

    socket
    |> assign(
      page_number: number,
      page_count: Pagination.page_count(page.count, @page_size),
      connector_count: page.count
    )
    |> stream(:connectors, page.results, reset: true)
  end

  defp apply_action(socket, :index, _params), do: assign(socket, form: nil)

  defp apply_action(socket, :new, _params) do
    assign(socket, form: to_form(Connectors.form_to_create_connector()))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Connectors.get_connector(id) do
      {:ok, connector} ->
        assign(socket, form: to_form(Connectors.form_to_update_connector(connector)))

      {:error, _} ->
        socket
        |> put_flash(:error, "Connector not found.")
        |> push_patch(to: current_path(socket.assigns))
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: list_path(filters(params), 1))}
  end

  def handle_event("validate", %{"form" => params}, socket) do
    {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, connector} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{connector.name} saved.")
         |> push_patch(to: current_path(socket.assigns))}

      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("connect", %{"id" => id}, socket) do
    with {:ok, connector} <- Connectors.get_connector(id),
         {:ok, connector} <- Connectors.authenticate_connector(connector) do
      {:noreply,
       socket
       |> put_connect_flash(connector)
       |> push_patch(to: current_path(socket.assigns))}
    else
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not connect the connector.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, connector} <- Connectors.get_connector(id),
         :ok <- Connectors.remove_connector(connector) do
      {:noreply,
       socket
       |> put_flash(:info, "#{connector.name} removed, with its auth data.")
       |> push_patch(to: current_path(socket.assigns))}
    else
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not remove the connector.")}
    end
  end

  defp put_connect_flash(socket, %{status: :connected} = connector) do
    put_flash(socket, :info, "#{connector.name} connected.")
  end

  defp put_connect_flash(socket, connector) do
    put_flash(socket, :error, connector.status_message)
  end

  defp current_path(assigns) do
    filters = Map.put(assigns.filters, :selected, assigns.selected && assigns.selected.id)
    list_path(filters, assigns.page_number)
  end

  defp list_path(filters, page_number), do: ~p"/connectors?#{query(filters, page_number)}"

  defp query(filters, page_number) do
    filters
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.put(:page, page_number)
  end

  defp adapter(connector), do: Provider.adapter(connector.provider)

  defp selected?(selected, connector), do: selected != nil and selected.id == connector.id

  defp tone(status), do: Map.fetch!(@tones, status)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:connectors}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <div class="mb-6 flex items-center justify-between">
        <h1 class="text-2xl font-semibold tracking-tight">Connectors</h1>
        <.button
          patch={~p"/connectors/new?#{query(@filters, @page_number)}"}
          variant="primary"
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-plus-micro" class="size-4" /> New
        </.button>
      </div>

      <form
        id="connector-filters"
        phx-change="filter"
        phx-submit="filter"
        class="mb-4 flex flex-wrap items-center gap-2"
      >
        <label class="input input-sm w-72">
          <.icon name="hero-magnifying-glass-micro" class="size-4 text-(--orpheus-text-muted)" />
          <input
            type="search"
            name="search"
            value={@filters.search}
            placeholder="Search by name"
            aria-label="Search connectors by name"
            phx-debounce="300"
          />
        </label>
        <select name="provider" aria-label="Filter by provider" class="select select-sm w-44">
          <option value="">All providers</option>
          <option
            :for={provider <- Provider.values()}
            value={provider}
            selected={provider == @filters.provider}
          >
            {Provider.adapter(provider).label()}
          </option>
        </select>
        <select name="status" aria-label="Filter by status" class="select select-sm w-40">
          <option value="">All statuses</option>
          <option :for={status <- Status.values()} value={status} selected={status == @filters.status}>
            {Status.label(status)}
          </option>
        </select>
      </form>

      <.table
        id="connectors"
        rows={@streams.connectors}
        row_item={fn {_id, connector} -> connector end}
        row_class={fn {_id, connector} -> selected?(@selected, connector) && "orpheus-selected" end}
      >
        <:col :let={connector} label="Connector">
          <div class="flex items-center gap-3">
            <img src={adapter(connector).avatar()} alt="" class="size-7 shrink-0 rounded-md" />
            <span class="font-medium text-base-content">{connector.name}</span>
          </div>
        </:col>
        <:col :let={connector} label="Provider">{adapter(connector).label()}</:col>
        <:col :let={connector} label="Status">
          <span class={["orpheus-badge", "tone-#{tone(connector.status)}"]}>
            {Status.label(connector.status)}
          </span>
          <p :if={connector.status_message} class="mt-1 max-w-xs text-xs text-error">
            {connector.status_message}
          </p>
        </:col>
        <:col :let={connector} label="Account">
          <span :if={connector.auth}>
            {connector.auth.metadata["email"]}
            <span
              :if={connector.auth.metadata["subscriptionType"]}
              class="text-(--orpheus-text-muted)"
            >
              · {connector.auth.metadata["subscriptionType"]}
            </span>
          </span>
          <span :if={!connector.auth} class="text-(--orpheus-text-muted)">—</span>
        </:col>
        <:col :let={connector} label="Verified">
          <span :if={connector.auth}>
            {Calendar.strftime(connector.auth.verified_at, "%b %-d, %H:%M")}
          </span>
        </:col>
        <:action :let={connector}>
          <.link
            phx-click="connect"
            phx-value-id={connector.id}
            phx-disable-with="Connecting…"
            aria-label={"Connect #{connector.name}"}
            class="text-primary"
          >
            {if connector.status == :connected, do: "Reconnect", else: "Connect"}
          </.link>
        </:action>
        <:action :let={connector}>
          <.link
            patch={~p"/connectors/#{connector.id}/edit?#{query(@filters, @page_number)}"}
            aria-label={"Edit #{connector.name}"}
          >
            Edit
          </.link>
        </:action>
        <:action :let={connector}>
          <.link
            phx-click="delete"
            phx-value-id={connector.id}
            data-confirm={
              "Remove #{connector.name}? Its stored auth data is deleted and linked agents are unlinked."
            }
            aria-label={"Remove #{connector.name}"}
            class="text-error"
          >
            Remove
          </.link>
        </:action>
      </.table>

      <div
        :if={@selected}
        id={"focus-#{@selected.id}"}
        phx-hook=".FocusSelected"
        data-row={"connectors-#{@selected.id}"}
        hidden
      >
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".FocusSelected">
        export default {
          mounted() {
            const row = document.getElementById(this.el.dataset.row)
            if (!row) return
            row.tabIndex = -1
            row.scrollIntoView({block: "center"})
            row.focus({preventScroll: true})
          },
        }
      </script>

      <p :if={@connector_count == 0} class="py-8 text-center text-sm text-(--orpheus-text-muted)">
        No connectors found.
      </p>

      <.pagination
        page_number={@page_number}
        page_count={@page_count}
        path={&list_path(@filters, &1)}
      />

      <.modal :if={@form} id="connector-modal" on_cancel={JS.patch(list_path(@filters, @page_number))}>
        <:title>{if @live_action == :new, do: "New connector", else: "Edit connector"}</:title>
        <.form for={@form} id="connector-form" phx-change="validate" phx-submit="save">
          <.input
            :if={@live_action == :new}
            field={@form[:provider]}
            type="select"
            label="Provider"
            options={Enum.map(Provider.values(), &{Provider.adapter(&1).label(), &1})}
          />
          <.input
            field={@form[:name]}
            label="Name"
            placeholder="e.g. My Claude Code"
            phx-mounted={JS.focus()}
          />
          <p :if={@live_action == :new} class="mb-2 text-xs text-(--orpheus-text-muted)">
            After saving, use Connect. Claude Code connects through your computer's own login via <code>bin/claude_bridge</code>; no credentials are copied into the app.
          </p>
          <div class="mt-4 flex justify-end gap-2">
            <.button patch={list_path(@filters, @page_number)} class="btn btn-ghost btn-sm">Cancel</.button>
            <.button variant="primary" class="btn btn-primary btn-sm" phx-disable-with="Saving…">
              Save
            </.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end
end
