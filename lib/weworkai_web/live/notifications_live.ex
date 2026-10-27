defmodule WeworkaiWeb.NotificationsLive do
  @moduledoc """
  Every notification, newest first (the latest 100), optionally only the unread ones.
  Opening and marking read are the bell's events (`WeworkaiWeb.NotificationsHook`).
  """
  use WeworkaiWeb, :live_view

  @behaviour WeworkaiWeb.NotificationsHook

  import WeworkaiWeb.NotificationComponents, only: [notification_row: 1]

  alias Weworkai.Notifications

  @limit 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Notifications")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, socket |> assign(unread_only: params["filter"] == "unread") |> load_inbox()}
  end

  defp load_inbox(socket) do
    notifications = Notifications.list_notifications!(socket.assigns.unread_only, @limit)

    socket
    |> assign(truncated?: length(notifications) == @limit)
    |> stream(:inbox, notifications, reset: true)
  end

  @impl WeworkaiWeb.NotificationsHook
  def handle_notification({:created, notification}, socket) do
    stream_insert(socket, :inbox, notification, at: 0, limit: @limit)
  end

  def handle_notification(:read, socket), do: load_inbox(socket)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:notifications}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <div class="mx-auto max-w-3xl">
        <div class="mb-6 flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Notifications</h1>
            <p class="mt-1 text-sm text-(--orpheus-text-muted)">
              What the agents did with your tasks.
            </p>
          </div>
          <div class="flex items-center gap-3">
            <nav
              id="notifications-filter"
              aria-label="Filter"
              class="flex rounded-lg border border-(--orpheus-border) bg-base-200 p-0.5 text-sm"
            >
              <.filter_link id="filter-all" patch={~p"/notifications"} active={not @unread_only}>
                All
              </.filter_link>
              <.filter_link
                id="filter-unread"
                patch={~p"/notifications?filter=unread"}
                active={@unread_only}
              >
                Unread
                <span
                  :if={@unread_count > 0}
                  class="ml-1 bg-primary px-1.5 text-[10px] font-semibold text-primary-content tabular-nums"
                >
                  {@unread_count}
                </span>
              </.filter_link>
            </nav>
            <button
              id="notifications-mark-all-read"
              type="button"
              phx-click="mark_all_notifications_read"
              disabled={@unread_count == 0}
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-check-micro" class="size-4" /> Mark all read
            </button>
          </div>
        </div>

        <ul
          id="inbox"
          phx-update="stream"
          class="orpheus-card divide-y divide-(--orpheus-border) overflow-hidden"
        >
          <li
            id="inbox-empty"
            class="hidden flex-col items-center gap-2 px-4 py-16 text-center text-sm text-(--orpheus-text-muted) only:flex"
          >
            <.icon name="hero-bell-slash" class="size-7" />
            {if @unread_only, do: "No unread notifications.", else: "No notifications yet."}
          </li>
          <li :for={{dom_id, notification} <- @streams.inbox} id={dom_id}>
            <.notification_row id={"#{dom_id}-open"} notification={notification} />
          </li>
        </ul>
        <p
          :if={@truncated?}
          id="inbox-limit"
          class="mt-3 text-center text-xs text-(--orpheus-text-muted)"
        >
          Showing the latest 100.
        </p>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :patch, :string, required: true
  attr :active, :boolean, required: true
  slot :inner_block, required: true

  defp filter_link(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@patch}
      aria-current={@active && "page"}
      class={[
        "flex items-center rounded-md px-3 py-1 transition-colors",
        if(@active,
          do: "bg-(--orpheus-card) font-medium text-base-content shadow-sm",
          else: "text-(--orpheus-text-muted) hover:text-base-content"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
