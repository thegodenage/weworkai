defmodule WeworkaiWeb.FolderPicker do
  @moduledoc """
  A folder field with a browser of the folders agents may use. The Claude bridge lists them:
  it runs on the user's computer, whose folders the app's container cannot see.
  """
  use WeworkaiWeb, :live_component

  alias Weworkai.Connectors.ClaudeBridge

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         listing: nil,
         error: nil,
         label: nil,
         debounce: nil,
         class: "input w-full font-mono"
       )}

  @impl true
  def handle_event("browse", %{"path" => path}, socket) do
    {:noreply, browse(socket, String.trim(path))}
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, listing: nil, error: nil)}
  end

  # A folder that can't be listed (typed by hand, or outside the allowed ones) falls back to
  # the allowed folders, with the reason above them.
  defp browse(socket, path) do
    case ClaudeBridge.folders(path) do
      {:ok, listing} ->
        assign(socket, listing: listing, error: nil)

      {:error, error} when path != "" ->
        socket |> browse("") |> assign(error: error)

      {:error, error} ->
        assign(socket, listing: nil, error: error)
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        errors:
          if(Phoenix.Component.used_input?(assigns.field),
            do: Enum.map(assigns.field.errors, &translate_error/1),
            else: []
          )
      )

    ~H"""
    <div
      id={@id}
      class={["relative", @label && "fieldset mb-2"]}
      phx-hook=".FolderPicker"
      phx-target={@myself}
    >
      <label :if={@label} for={"#{@id}-input"} class="label mb-1">{@label}</label>
      <div class="flex items-center gap-1.5">
        <input
          id={"#{@id}-input"}
          name={@field.name}
          value={@field.value}
          aria-label="Folder"
          placeholder={Weworkai.Board.Task.default_repository()}
          phx-debounce={@debounce}
          autocomplete="off"
          class={[@class, @errors != [] && "input-error"]}
        />
        <button
          type="button"
          id={"#{@id}-browse"}
          data-browse
          aria-expanded={to_string(@listing != nil)}
          title="Browse folders"
          class="btn btn-ghost btn-sm btn-square transition-colors"
        >
          <.icon name="hero-folder-open-micro" class="size-4" />
        </button>
      </div>
      <p :for={message <- @errors} class="mt-1 text-sm text-error">Repository {message}</p>

      <div
        :if={@listing || @error}
        id={"#{@id}-panel"}
        data-panel
        phx-click-away="close"
        phx-target={@myself}
        class="hard-shadow absolute top-full left-0 z-50 mt-1 w-80 max-w-[90vw] overflow-hidden border border-(--orpheus-border-strong) bg-(--orpheus-card)"
      >
        <div
          :if={@listing}
          class="flex items-center gap-1 border-b border-(--orpheus-border) px-2 py-1.5"
        >
          <button
            :if={@listing["path"]}
            type="button"
            id={"#{@id}-up"}
            phx-click="browse"
            phx-value-path={@listing["parent"] || ""}
            phx-target={@myself}
            title="Up"
            class="btn btn-ghost btn-xs btn-square"
          >
            <.icon name="hero-arrow-up-micro" class="size-4" />
          </button>
          <code class="min-w-0 flex-1 truncate px-1 text-xs" title={@listing["path"]}>
            {@listing["path"] || "Allowed folders"}
          </code>
        </div>
        <p :if={@error} id={"#{@id}-error"} class="px-3 py-2 text-xs text-error">{@error}</p>
        <ul :if={@listing} id={"#{@id}-folders"} class="max-h-64 overflow-y-auto py-1">
          <li
            :if={@listing["folders"] == []}
            class="px-3 py-2 text-xs text-(--orpheus-text-muted)"
          >
            No folders inside
          </li>
          <li
            :for={folder <- @listing["folders"]}
            class="group flex items-center gap-1 px-1 transition-colors hover:bg-(--orpheus-hover)"
          >
            <button
              type="button"
              phx-click="browse"
              phx-value-path={folder["path"]}
              phx-target={@myself}
              class="flex min-w-0 flex-1 items-center gap-2 px-2 py-1.5 text-left text-sm"
            >
              <.icon name="hero-folder-micro" class="size-4 shrink-0 text-(--orpheus-text-muted)" />
              <span class="truncate">{folder["name"]}</span>
              <span
                :if={folder["git"]}
                class="rounded bg-base-300 px-1.5 text-[10px] text-(--orpheus-text-secondary)"
              >
                git
              </span>
            </button>
            <button
              type="button"
              data-choose={folder["path"]}
              class="btn btn-ghost btn-xs opacity-0 transition-opacity group-hover:opacity-100 focus:opacity-100"
            >
              Select
            </button>
          </li>
        </ul>
        <div
          :if={@listing && @listing["path"]}
          class="flex justify-end border-t border-(--orpheus-border) px-2 py-1.5"
        >
          <button
            type="button"
            id={"#{@id}-choose"}
            data-choose={@listing["path"]}
            class="btn btn-primary btn-xs"
          >
            Use this folder
          </button>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".FolderPicker">
        export default {
          mounted() {
            // Captured on window before LiveView's own window keydown bindings: an open folder
            // list takes Escape for itself, so the drawer or modal around it stays open.
            this.onEscape = event => {
              if (event.key !== "Escape" || !this.el.querySelector("[data-panel]")) return
              event.stopImmediatePropagation()
              this.pushEventTo(this.el, "close", {})
            }
            window.addEventListener("keydown", this.onEscape, true)
            this.el.addEventListener("click", event => {
              const input = this.el.querySelector("input")
              if (event.target.closest("[data-browse]")) {
                const open = this.el.querySelector("[data-panel]")
                this.pushEventTo(this.el, open ? "close" : "browse", {path: input.value})
              }
              const chosen = event.target.closest("[data-choose]")
              if (chosen) {
                input.value = chosen.dataset.choose
                // focus and blur flush a blur-debounced input, so its form sees the change at once
                input.focus()
                input.dispatchEvent(new Event("input", {bubbles: true}))
                input.blur()
                this.pushEventTo(this.el, "close", {})
              }
            })
          },
          destroyed() {
            window.removeEventListener("keydown", this.onEscape, true)
          }
        }
      </script>
    </div>
    """
  end
end
