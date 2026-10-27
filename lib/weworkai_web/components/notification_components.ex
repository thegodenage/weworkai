defmodule WeworkaiWeb.NotificationComponents do
  @moduledoc """
  The notification bell, its panel and the rows shared by the panel and the
  notifications page. Their events are handled by `WeworkaiWeb.NotificationsHook`.
  """
  use Phoenix.Component
  use WeworkaiWeb, :verified_routes

  import WeworkaiWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS

  attr :notifications, :list, required: true
  attr :unread_count, :integer, required: true

  def bell(assigns) do
    ~H"""
    <div
      id="notification-bell"
      class="relative"
      phx-click-away={close_panel()}
      phx-window-keydown={close_panel()}
      phx-key="Escape"
    >
      <button
        id="notification-bell-button"
        type="button"
        phx-click={toggle_panel()}
        aria-label={bell_label(@unread_count)}
        aria-haspopup="dialog"
        aria-expanded="false"
        aria-controls="notification-panel"
        class="relative flex size-9 cursor-pointer items-center justify-center rounded-lg text-(--orpheus-text-muted) transition-colors hover:bg-(--orpheus-hover) hover:text-base-content aria-expanded:bg-(--orpheus-nav-active) aria-expanded:text-(--orpheus-nav-active-text)"
      >
        <.icon
          name="hero-bell"
          class={[
            "size-5",
            @unread_count > 0 && "origin-top motion-safe:animate-[bell-ring_0.6s_ease-in-out]"
          ]}
        />
        <span
          :if={@unread_count > 0}
          id="notification-bell-count"
          class="absolute -top-0.5 -right-0.5 flex h-4 min-w-4 items-center justify-center bg-primary px-1 text-[10px] leading-none font-semibold text-primary-content ring-2 ring-base-100 tabular-nums"
        >
          {badge(@unread_count)}
        </span>
      </button>

      <div
        id="notification-panel"
        role="dialog"
        aria-label="Notifications"
        class="fixed top-4 left-16 z-50 hidden w-[min(24rem,calc(100vw-5rem))] overflow-hidden rounded-xl border border-(--orpheus-border) bg-(--orpheus-card) shadow-2xl shadow-black/20 sm:left-[16.5rem]"
      >
        <div class="flex items-center justify-between gap-3 border-b border-(--orpheus-border) px-4 py-3">
          <div class="flex items-center gap-2">
            <h2 class="text-sm font-semibold">Notifications</h2>
            <span
              :if={@unread_count > 0}
              id="notification-panel-unread"
              class="orpheus-badge tone-blue"
            >
              {@unread_count} new
            </span>
          </div>
          <button
            :if={@unread_count > 0}
            id="mark-all-notifications-read"
            type="button"
            phx-click="mark_all_notifications_read"
            class="cursor-pointer rounded-md px-2 py-1 text-xs font-medium text-primary transition-colors hover:bg-primary/10"
          >
            Mark all read
          </button>
        </div>

        <ul id="notification-list" class="max-h-[60vh] overflow-y-auto">
          <li
            :if={@notifications == []}
            id="notification-list-empty"
            class="flex flex-col items-center gap-2 px-4 py-10 text-center text-sm text-(--orpheus-text-muted)"
          >
            <.icon name="hero-bell-slash" class="size-6" /> You're all caught up.
          </li>
          <li
            :for={notification <- @notifications}
            class="border-b border-(--orpheus-border) last:border-b-0"
          >
            <.notification_row id={"notification-#{notification.id}"} notification={notification} />
          </li>
        </ul>

        <div class="flex items-center justify-between gap-2 border-t border-(--orpheus-border) bg-base-200/50 px-4 py-2.5">
          <button
            id="enable-desktop-notifications"
            type="button"
            phx-click={JS.dispatch("notifications:enable-desktop")}
            class="desktop-notifications-toggle inline-flex cursor-pointer items-center gap-1.5 text-xs text-(--orpheus-text-muted) transition-colors hover:text-base-content"
          >
            <.icon name="hero-computer-desktop-micro" class="size-4" />
            <span data-permission="default">Enable desktop notifications</span>
            <span data-permission="granted">Desktop notifications on</span>
            <span data-permission="denied">Desktop notifications blocked</span>
          </button>
          <.link
            id="notification-panel-all"
            navigate={~p"/notifications"}
            class="text-xs font-medium text-primary hover:underline"
          >
            View all
          </.link>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  One notification. A click marks it read and opens its task (`open_notification`).
  """
  attr :id, :string, required: true
  attr :notification, :map, required: true

  def notification_row(assigns) do
    ~H"""
    <a
      id={@id}
      href="#"
      phx-click={JS.push("open_notification", value: %{id: @notification.id}) |> close_panel()}
      data-unread={is_nil(@notification.read_at)}
      class={[
        "group flex gap-3 px-4 py-3 transition-colors hover:bg-(--orpheus-hover)",
        is_nil(@notification.read_at) && "bg-primary/[0.04]"
      ]}
    >
      <span class={[
        "orpheus-tile mt-0.5 size-7 shrink-0",
        "tone-#{kind_tone(@notification.kind)}"
      ]}>
        <.icon name={kind_icon(@notification.kind)} class="size-4" />
      </span>
      <span class="min-w-0 flex-1">
        <span class="flex items-start justify-between gap-2">
          <span
            title={@notification.title}
            class={[
              "line-clamp-2 min-w-0 text-sm leading-snug [overflow-wrap:anywhere]",
              if(is_nil(@notification.read_at),
                do: "font-medium text-base-content",
                else: "text-(--orpheus-text-secondary)"
              )
            ]}
          >
            {@notification.title}
          </span>
          <span
            :if={is_nil(@notification.read_at)}
            class="mt-1.5 size-2 shrink-0 rounded-full bg-primary"
            aria-label="Unread"
          />
        </span>
        <span
          :if={@notification.body}
          class="mt-0.5 line-clamp-2 text-xs [overflow-wrap:anywhere] text-(--orpheus-text-muted)"
        >
          {Weworkai.ErrorText.clean(@notification.body)}
        </span>
        <time
          datetime={DateTime.to_iso8601(@notification.inserted_at)}
          title={Calendar.strftime(@notification.inserted_at, "%b %-d, %H:%M UTC")}
          class="mt-1 block text-[11px] text-(--orpheus-text-muted)"
        >
          {relative_time(@notification.inserted_at)}
        </time>
      </span>
    </a>
    """
  end

  defp toggle_panel do
    JS.toggle(
      to: "#notification-panel",
      in: {"ease-out duration-150", "opacity-0 -translate-x-1", "opacity-100 translate-x-0"},
      out: {"ease-in duration-100", "opacity-100", "opacity-0"}
    )
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#notification-bell-button")
  end

  defp close_panel(js \\ %JS{}) do
    js
    |> JS.hide(
      to: "#notification-panel",
      transition: {"ease-in duration-100", "opacity-100", "opacity-0"}
    )
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#notification-bell-button")
  end

  defp bell_label(0), do: "Notifications"
  defp bell_label(count), do: "Notifications, #{count} unread"

  defp badge(count) when count > 99, do: "99+"
  defp badge(count), do: count

  def kind_icon(:started), do: "hero-play-micro"
  def kind_icon(:plan_ready), do: "hero-map-micro"
  def kind_icon(:needs_answers), do: "hero-question-mark-circle-micro"
  def kind_icon(:ready_for_review), do: "hero-check-badge-micro"
  def kind_icon(:ready_to_merge), do: "hero-check-badge-micro"
  def kind_icon(:answer_ready), do: "hero-sparkles-micro"
  def kind_icon(:stage_skipped), do: "hero-forward-micro"
  def kind_icon(:agent_failed), do: "hero-exclamation-triangle-micro"
  def kind_icon(:agent_stalled), do: "hero-clock-micro"
  def kind_icon(:decision_needed), do: "hero-hand-raised-micro"
  def kind_icon(:workflow_stuck), do: "hero-no-symbol-micro"
  def kind_icon(:budget_warning), do: "hero-banknotes-micro"
  def kind_icon(:budget_reached), do: "hero-banknotes-micro"
  def kind_icon(:unblocked), do: "hero-lock-open-micro"

  def kind_tone(:started), do: "blue"
  def kind_tone(:plan_ready), do: "violet"
  def kind_tone(:needs_answers), do: "amber"
  def kind_tone(:ready_for_review), do: "green"
  def kind_tone(:ready_to_merge), do: "green"
  def kind_tone(:answer_ready), do: "violet"
  def kind_tone(:stage_skipped), do: "slate"
  def kind_tone(:agent_failed), do: "red"
  def kind_tone(:agent_stalled), do: "amber"
  def kind_tone(:decision_needed), do: "amber"
  def kind_tone(:workflow_stuck), do: "red"
  def kind_tone(:budget_warning), do: "amber"
  def kind_tone(:budget_reached), do: "red"
  def kind_tone(:unblocked), do: "green"

  @doc "How long ago, as of the last render."
  def relative_time(datetime) do
    case DateTime.diff(DateTime.utc_now(), datetime) do
      seconds when seconds < 60 -> "just now"
      seconds when seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds when seconds < 7 * 86_400 -> "#{div(seconds, 86_400)}d ago"
      _older -> Calendar.strftime(datetime, "%b %-d")
    end
  end
end
