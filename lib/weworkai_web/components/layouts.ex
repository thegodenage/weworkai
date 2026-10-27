defmodule WeworkaiWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use WeworkaiWeb, :html

  import WeworkaiWeb.NotificationComponents, only: [bell: 1]

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active, :atom,
    required: true,
    values: [:dashboard, :kanban, :audit, :workflows, :employees, :connectors, :notifications]

  attr :notifications, :list, required: true, doc: "recent notifications, from NotificationsHook"
  attr :unread_count, :integer, required: true, doc: "from NotificationsHook"

  attr :bleed, :boolean,
    default: false,
    doc: "fills the whole area beside the sidebar, without padding or page scroll (an editor)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <%!-- An editor (bleed) keeps the narrow rail on every screen: it needs the width. --%>
      <nav
        aria-label="Main"
        data-rail={@bleed}
        class="orpheus-sidebar group/nav sticky top-0 z-40 flex h-screen w-14 shrink-0 flex-col bg-base-100 px-2 pt-6 pb-4 sm:w-64 sm:px-4 sm:data-rail:w-14 sm:data-rail:px-2"
      >
        <div class="mb-8 flex flex-col items-center gap-3 sm:flex-row sm:justify-between sm:gap-2 sm:group-data-rail/nav:flex-col sm:group-data-rail/nav:gap-3">
          <.link navigate={~p"/"} class="flex items-center gap-2 sm:px-1">
            <img src={~p"/images/emblem_white.png"} alt="" class="emblem-dark size-8 shrink-0" />
            <img src={~p"/images/emblem_black.png"} alt="" class="emblem-light size-8 shrink-0" />
            <span class="sr-only flex-col sm:not-sr-only sm:flex sm:group-data-rail/nav:sr-only">
              <span class="text-sm leading-none font-bold tracking-[0.12em] uppercase">
                Weworkai
              </span>
              <span class="micro-label mt-1.5 leading-none">// by WeWorkAI</span>
            </span>
          </.link>
          <.bell notifications={@notifications} unread_count={@unread_count} />
        </div>
        <button
          id="command-palette-trigger"
          type="button"
          phx-click={JS.dispatch("command-palette:open")}
          aria-label="Search (⌘K)"
          aria-haspopup="dialog"
          class="mb-6 flex cursor-pointer items-center justify-center gap-2 border border-(--orpheus-border-strong) px-2 py-1.5 text-xs text-(--orpheus-text-muted) transition-colors hover:border-primary hover:text-base-content sm:justify-start sm:px-3 sm:group-data-rail/nav:justify-center sm:group-data-rail/nav:px-2"
        >
          <.icon name="hero-magnifying-glass-micro" class="size-4 shrink-0" />
          <span class="sr-only sm:not-sr-only sm:flex-1 sm:text-left sm:group-data-rail/nav:sr-only">
            Search
          </span>
          <kbd class="hidden text-[10px] tracking-wider sm:inline sm:group-data-rail/nav:hidden">
            ⌘K
          </kbd>
        </button>
        <p class="micro-label mb-2 hidden items-center gap-2 px-3 sm:flex sm:group-data-rail/nav:hidden">
          Workspace <span class="h-px flex-1 border-t border-dashed border-(--orpheus-border)"></span>
        </p>
        <ul class="space-y-px">
          <li>
            <.nav_link
              navigate={~p"/dashboard"}
              icon="hero-squares-2x2"
              active={@active == :dashboard}
            >
              Dashboard
            </.nav_link>
          </li>
          <li>
            <.nav_link navigate={~p"/"} icon="hero-view-columns" active={@active == :kanban}>
              Kanban
            </.nav_link>
          </li>
          <li>
            <.nav_link
              navigate={~p"/audit"}
              icon="hero-chart-bar-square"
              active={@active == :audit}
            >
              Audit
            </.nav_link>
          </li>
          <li>
            <.nav_link
              navigate={~p"/workflows"}
              icon="hero-arrows-right-left"
              active={@active == :workflows}
            >
              Workflows
            </.nav_link>
          </li>
          <li>
            <.nav_link navigate={~p"/employees"} icon="hero-users" active={@active == :employees}>
              Employees
            </.nav_link>
          </li>
          <li>
            <.nav_link
              navigate={~p"/connectors"}
              icon="hero-puzzle-piece"
              active={@active == :connectors}
            >
              Connectors
            </.nav_link>
          </li>
        </ul>
        <%!-- ponytail: no room on the narrow mobile rail; theme follows the system there. --%>
        <div class="mt-auto hidden sm:block sm:group-data-rail/nav:hidden"><.theme_toggle /></div>
      </nav>

      <main class={[
        "min-w-0 flex-1",
        if(@bleed, do: "h-screen overflow-hidden", else: "px-4 py-8 sm:px-12")
      ]}>
        {render_slot(@inner_block)}
      </main>
    </div>

    <.flash_group flash={@flash} />
    <.notification_toasts />
    <.live_component module={WeworkaiWeb.CommandPalette} id="command-palette" />
    """
  end

  # Toasts for the "notification" events NotificationsHook pushes; while the tab is hidden,
  # desktop notifications instead (once the person allowed them from the bell panel). The
  # newest shows on top and three at most: the rest wait behind a "+N more" chip that opens
  # the bell's list, so a burst never buries the page. A toast's six seconds only run while
  # it shows and the pointer or focus isn't on the toasts.
  defp notification_toasts(assigns) do
    ~H"""
    <div
      id="notification-toasts"
      phx-hook=".NotificationToasts"
      phx-update="ignore"
      aria-live="polite"
      class="pointer-events-none fixed right-4 bottom-4 z-50 flex w-80 flex-col items-end gap-2 sm:w-96"
    >
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".NotificationToasts">
      const TOAST_MS = 6000
      const VISIBLE = 3
      const permission = () => ("Notification" in window ? Notification.permission : "unsupported")
      const showPermission = () => {
        document.documentElement.dataset.desktopNotifications = permission()
      }

      export default {
        mounted() {
          showPermission()
          this.enableDesktop = () => {
            if (permission() === "default") Notification.requestPermission().then(showPermission)
          }
          window.addEventListener("notifications:enable-desktop", this.enableDesktop)
          this.held = false
          const hold = (held) => () => {
            this.held = held
            this.layout()
          }
          this.el.addEventListener("pointerenter", hold(true))
          this.el.addEventListener("pointerleave", hold(false))
          this.el.addEventListener("focusin", hold(true))
          // Later, not inside the blur: removing a focused chip blurs it, and laying out
          // again from there would remove the chips a second time mid-removal.
          this.el.addEventListener("focusout", () => {
            setTimeout(() => this.el.contains(document.activeElement) || hold(false)())
          })
          this.handleEvent("notification", (notification) => {
            if (document.hidden && permission() === "granted") this.desktop(notification)
            else this.toast(notification)
          })
        },

        destroyed() {
          window.removeEventListener("notifications:enable-desktop", this.enableDesktop)
        },

        // A page with unsaved work (the workflow editor) may keep the person there.
        open(notification) {
          if (!window.dispatchEvent(new Event("app:leave", {cancelable: true}))) return false
          this.pushEvent("open_notification", {id: notification.id})
          return true
        },

        toasts() {
          return [...this.el.querySelectorAll(".notification-toast:not(.leaving)")]
        },

        // Each toast keeps the time it has left; it only counts down while it shows.
        run(toast) {
          if (toast.timer) return
          toast.started = Date.now()
          toast.timer = setTimeout(() => this.dismiss(toast), toast.remaining)
        },

        pause(toast) {
          if (!toast.timer) return
          clearTimeout(toast.timer)
          toast.timer = null
          toast.remaining -= Date.now() - toast.started
        },

        layout() {
          const toasts = this.toasts()
          toasts.forEach((toast, index) => {
            const waiting = index >= VISIBLE
            toast.classList.toggle("hidden", waiting)
            waiting || this.held ? this.pause(toast) : this.run(toast)
          })
          this.chips(toasts.length - VISIBLE, toasts.length)
        },

        // "+N more" (opens the bell's list) and "Dismiss all", below the toasts.
        chips(hidden, total) {
          let row = this.el.querySelector("#notification-toasts-chips")
          if (total < 2) return row?.remove()
          if (!row) {
            row = document.createElement("div")
            row.id = "notification-toasts-chips"
            row.className = "pointer-events-auto flex items-center gap-1.5"
            const chip = (id, onClick) => {
              const button = document.createElement("button")
              button.type = "button"
              button.id = id
              button.className =
                "hard-shadow cursor-pointer border border-(--orpheus-border-strong) bg-(--orpheus-card) px-3 py-1 text-[11px] font-medium tracking-wider text-(--orpheus-text-secondary) uppercase transition-colors hover:text-base-content"
              button.addEventListener("click", onClick)
              return button
            }
            const more = chip("notification-toasts-more", (event) => {
              // The bell's click-away would close its panel again on this very click.
              event.stopPropagation()
              document.getElementById("notification-bell-button")?.click()
            })
            more.setAttribute("aria-haspopup", "dialog")
            const dismiss = chip("notification-toasts-dismiss", () => this.toasts().forEach((toast) => this.dismiss(toast)))
            dismiss.textContent = "Dismiss all"
            row.append(more, dismiss)
            this.el.append(row)
          }
          const more = row.querySelector("#notification-toasts-more")
          more.classList.toggle("hidden", hidden <= 0)
          more.textContent = `+${hidden} more`
          more.ariaLabel = `${hidden} more notifications: open the list`
        },

        desktop(notification) {
          const desktop = new Notification(notification.title, {
            body: notification.body ?? "",
            tag: notification.id,
          })
          desktop.onclick = () => {
            window.focus()
            this.open(notification)
            desktop.close()
          }
        },

        toast(notification) {
          const toast = document.createElement("div")
          toast.dataset.notificationId = notification.id
          toast.className =
            "notification-toast hard-shadow pointer-events-auto flex w-full items-start gap-3 border border-(--orpheus-border-strong) bg-(--orpheus-card) p-3"

          const icon = document.createElement("span")
          icon.className = `orpheus-tile mt-0.5 size-7 shrink-0 ${notification.tone}`
          const glyph = document.createElement("span")
          glyph.className = `${notification.icon} size-4`
          icon.append(glyph)

          const open = document.createElement("button")
          open.type = "button"
          open.className = "min-w-0 flex-1 cursor-pointer text-left"
          const title = document.createElement("span")
          title.className = "line-clamp-2 text-sm leading-snug font-medium [overflow-wrap:anywhere]"
          title.textContent = notification.title
          title.title = notification.title
          open.append(title)
          if (notification.body) {
            const body = document.createElement("span")
            body.className = "mt-0.5 line-clamp-2 text-xs [overflow-wrap:anywhere] text-(--orpheus-text-muted)"
            body.textContent = notification.body
            open.append(body)
          }
          open.addEventListener("click", () => {
            if (this.open(notification)) this.dismiss(toast)
          })

          const close = document.createElement("button")
          close.type = "button"
          close.ariaLabel = "Dismiss"
          close.className = "cursor-pointer rounded p-0.5 text-(--orpheus-text-muted) transition-colors hover:text-base-content"
          const x = document.createElement("span")
          x.className = "hero-x-mark-micro size-4"
          close.append(x)
          close.addEventListener("click", () => this.dismiss(toast))

          toast.append(icon, open, close)
          toast.remaining = TOAST_MS
          this.el.prepend(toast)
          this.layout()
        },

        dismiss(toast) {
          if (toast.classList.contains("leaving")) return
          this.pause(toast)
          toast.classList.add("leaving")
          toast.addEventListener("animationend", () => toast.remove(), {once: true})
          if (toast.classList.contains("hidden")) toast.remove()
          this.layout()
        },
      }
    </script>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, required: true
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@active && "page"}
      class="orpheus-nav-link flex items-center gap-3 px-3 py-2"
    >
      <.icon name={@icon} class="orpheus-nav-icon size-5 shrink-0" />
      <span class="sr-only sm:not-sr-only sm:group-data-rail/nav:sr-only">
        {render_slot(@inner_block)}
      </span>
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  # The chosen option is inverted; written out per option so Tailwind sees each class.
  @themes [
    {"system", "Sys",
     "[[data-theme-source=system]_&]:bg-base-content [[data-theme-source=system]_&]:text-base-100"},
    {"light", "Lgt",
     "[[data-theme-source=user][data-theme=light]_&]:bg-base-content [[data-theme-source=user][data-theme=light]_&]:text-base-100"},
    {"dark", "Drk",
     "[[data-theme-source=user][data-theme=dark]_&]:bg-base-content [[data-theme-source=user][data-theme=dark]_&]:text-base-100"}
  ]

  @doc """
  Provides the system / light / dark theme switch for the themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    assigns = assign(assigns, :themes, @themes)

    ~H"""
    <div class="flex flex-col gap-1.5">
      <span class="micro-label">Theme</span>
      <div class="grid grid-cols-3 border border-(--orpheus-border-strong) text-[10px] tracking-wider uppercase">
        <button
          :for={{theme, label, chosen} <- @themes}
          class={[
            "cursor-pointer py-1 text-(--orpheus-text-muted) transition-colors not-first:border-l not-first:border-(--orpheus-border-strong) hover:text-base-content",
            chosen
          ]}
          phx-click={JS.dispatch("phx:set-theme")}
          data-phx-theme={theme}
          aria-label={"#{theme} theme"}
        >
          {label}
        </button>
      </div>
    </div>
    """
  end
end
