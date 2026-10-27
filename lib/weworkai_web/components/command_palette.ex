defmodule WeworkaiWeb.CommandPalette do
  @moduledoc """
  The ⌘K / Ctrl+K command palette (also "/" outside a field), rendered once by
  `WeworkaiWeb.Layouts.app/1`: fuzzy jumps to tasks, runs, workflows, employees and
  pages, and a few actions.

  The server searches (`Weworkai.Fuzzy`, a bounded `:search` read per resource) and
  renders the results; the colocated hook owns everything keyboard: opening, the active
  option, choosing it, and the recent picks it keeps in localStorage and sends on open.
  A LiveComponent so every LiveView gets it without handling its events.
  """
  use WeworkaiWeb, :live_component

  alias Weworkai.{Agents, Board, Fuzzy, Organization, Workflows}
  alias Weworkai.Board.Task.Status
  alias WeworkaiWeb.TaskComponents

  @per_group 5
  @recent_limit 5
  @label_length 80

  @pages [
    {"Dashboard", "/dashboard", "hero-squares-2x2"},
    {"Kanban", "/", "hero-view-columns"},
    {"Audit", "/audit", "hero-chart-bar-square"},
    {"Workflows", "/workflows", "hero-arrows-right-left"},
    {"Employees", "/employees", "hero-users"},
    {"Connectors", "/connectors", "hero-puzzle-piece"},
    {"Notifications", "/notifications", "hero-bell"}
  ]

  @actions [
    {"New task", "/tasks/new", "hero-plus"},
    {"New workflow", "/workflows/new", "hero-plus"},
    {"New employee", "/employees/new", "hero-user-plus"},
    {"Go to audit", "/audit", "hero-chart-bar-square"},
    {"Toggle theme", :theme, "hero-swatch"}
  ]

  # Results are only rendered while it is open: every page carries the closed palette.
  @impl true
  def mount(socket) do
    {:ok, assign(socket, open: false, query: "", recent: [], groups: [])}
  end

  @impl true
  def handle_event("open", %{"recent" => recent}, socket) do
    recent = recent_items(recent)

    {:noreply, assign(socket, open: true, query: "", recent: recent, groups: groups("", recent))}
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, open: false, query: "", groups: [])}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, query: query, groups: groups(query, socket.assigns.recent))}
  end

  @doc "The palette's result groups for a query: `{label, items}`, empty groups left out."
  def groups(query, recent) do
    query
    |> candidates(recent)
    |> Enum.reject(fn {_label, items} -> items == [] end)
  end

  defp candidates(query, recent) do
    case Fuzzy.new(query) do
      :error ->
        [{"Recent", recent}, {"Actions", actions()}, {"Pages", pages()}]

      {:ok, fuzzy} ->
        pattern = Fuzzy.pattern(fuzzy)

        [
          {"Tasks", pattern |> Board.search_tasks!() |> Enum.map(&task_item/1)},
          {"Runs", pattern |> Agents.search_runs!() |> Enum.map(&run_item/1)},
          {"Workflows", pattern |> Workflows.search_workflows!() |> Enum.map(&workflow_item/1)},
          {"Employees",
           pattern |> Organization.search_employees!() |> Enum.map(&employee_item/1)},
          {"Pages", pages()},
          {"Actions", actions()}
        ]
        |> Enum.map(fn {label, items} -> {label, rank(fuzzy, items)} end)
    end
  end

  defp rank(fuzzy, items) do
    for item <- items, match = Fuzzy.match(fuzzy, item.label) do
      Map.merge(item, match)
    end
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(@per_group)
  end

  defp item(label, target, icon, tag \\ nil, tone \\ nil),
    do: %{
      label: label,
      target: target,
      icon: icon,
      tag: tag,
      tone: tone,
      kind: nil,
      positions: []
    }

  defp pages, do: for({label, href, icon} <- @pages, do: item(label, href, icon))
  defp actions, do: for({label, target, icon} <- @actions, do: item(label, target, icon))

  defp task_item(task),
    do:
      item(
        task.title,
        ~p"/tasks/#{task.id}",
        "hero-rectangle-stack",
        Status.label(task.status),
        TaskComponents.status_tone(task.status)
      )

  defp run_item(run) do
    {tag, tone} = if run.stopped_at, do: {"Stopped", "slate"}, else: {"Active", "green"}
    label = "#{run.agent.employee.name}: #{first_line(run.task)}"
    item(label, ~p"/dashboard/runs/#{run.id}", "hero-command-line", tag, tone)
  end

  defp workflow_item(workflow),
    do: item(workflow.name, ~p"/workflows/#{workflow.id}", "hero-arrows-right-left")

  defp employee_item(employee) do
    tag = if employee.kind == :agent, do: "Agent", else: "Human"
    item(employee.name, ~p"/employees/#{employee.id}/edit", "hero-user", tag, "slate")
  end

  defp first_line(text),
    do: text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, @label_length)

  # Recent picks come from the browser: only what was stored by a pick, an app path.
  defp recent_items(recent) when is_list(recent) do
    recent
    |> Enum.take(@recent_limit)
    |> Enum.flat_map(fn
      %{"label" => label, "href" => "/" <> path = href, "kind" => kind}
      when is_binary(label) and is_binary(kind) ->
        if String.starts_with?(path, "/"),
          do: [],
          else: [
            %{item(String.slice(label, 0, @label_length), href, "hero-clock", kind) | kind: kind}
          ]

      _other ->
        []
    end)
  end

  defp recent_items(_recent), do: []

  defp segments(label, []), do: [{label, false}]

  defp segments(label, positions) do
    matched = MapSet.new(positions)

    label
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.chunk_by(fn {_grapheme, index} -> index in matched end)
    |> Enum.map(fn [{_grapheme, index} | _] = chunk ->
      {Enum.map_join(chunk, &elem(&1, 0)), index in matched}
    end)
  end

  defp group_id(label), do: "command-palette-group-#{String.downcase(label)}"

  # Stable across renders, so the hook keeps the active option while results update.
  defp option_id(label, item),
    do: "#{group_id(label)}-#{:erlang.phash2(item.target)}"

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} phx-hook=".CommandPalette" phx-target={@myself} class="contents">
      <div
        id="command-palette-dialog"
        role="dialog"
        aria-modal="true"
        aria-label="Command palette"
        hidden
        class="fixed inset-0 z-[60] flex items-start justify-center bg-(--orpheus-overlay) px-4 pt-[12vh] backdrop-blur-[1px]"
      >
        <div class="hard-shadow flex max-h-[70vh] w-full max-w-2xl flex-col border border-(--orpheus-border-strong) bg-(--orpheus-card) motion-safe:animate-[command-palette-in_0.12s_ease-out]">
          <form
            id="command-palette-form"
            phx-change="search"
            phx-target={@myself}
            autocomplete="off"
            class="flex items-center gap-3 border-b border-(--orpheus-border-strong) px-4"
          >
            <span aria-hidden="true" class="text-sm font-semibold text-primary">&gt;</span>
            <input
              id="command-palette-input"
              name="query"
              value={@query}
              type="text"
              role="combobox"
              aria-expanded="true"
              aria-controls="command-palette-results"
              aria-autocomplete="list"
              aria-label="Search tasks, runs, workflows, employees and pages"
              placeholder="Jump to a task, run, workflow, employee…"
              maxlength="64"
              spellcheck="false"
              phx-debounce="60"
              class="h-12 min-w-0 flex-1 bg-transparent text-sm caret-primary placeholder:text-(--orpheus-text-muted)"
            />
            <kbd class="orpheus-badge text-(--orpheus-text-muted)">Esc</kbd>
          </form>

          <div
            id="command-palette-results"
            role="listbox"
            aria-label="Results"
            class="min-h-0 flex-1 overflow-y-auto py-1"
          >
            <p
              :if={@open and @groups == []}
              id="command-palette-empty"
              class="px-4 py-8 text-center text-xs text-(--orpheus-text-muted)"
            >
              // no matches for “{@query}”
            </p>
            <div
              :for={{label, items} <- @groups}
              id={group_id(label)}
              role="group"
              aria-labelledby={"#{group_id(label)}-label"}
              class="pt-2 not-first:mt-1 not-first:border-t not-first:border-dashed not-first:border-(--orpheus-border)"
            >
              <p
                id={"#{group_id(label)}-label"}
                class="micro-label flex items-center gap-2 px-4 pb-1"
              >
                {label}
                <span class="h-px flex-1 border-t border-dashed border-(--orpheus-border)"></span>
                <span class="tabular-nums">{length(items)}</span>
              </p>
              <div
                :for={item <- items}
                id={option_id(label, item)}
                role="option"
                aria-selected="false"
                data-kind={item.kind || label}
                data-label={item.label}
                data-href={is_binary(item.target) && item.target}
                data-action={item.target == :theme && "theme"}
                class="group/option flex cursor-pointer items-center gap-3 px-4 py-1.5 text-sm text-(--orpheus-text-secondary) transition-colors aria-selected:bg-(--orpheus-nav-active) aria-selected:text-base-content aria-selected:shadow-[inset_2px_0_0_var(--color-primary)]"
              >
                <.icon
                  name={item.icon}
                  class="size-4 shrink-0 text-(--orpheus-text-muted) group-aria-selected/option:text-primary"
                />
                <span class="min-w-0 flex-1 truncate">
                  <span
                    :for={{text, matched} <- segments(item.label, item.positions)}
                    class={matched && "font-semibold text-primary underline underline-offset-3"}
                  >{text}</span>
                </span>
                <span
                  :if={item.tag}
                  class={["orpheus-badge shrink-0", item.tone && "tone-#{item.tone}"]}
                >
                  {item.tag}
                </span>
                <span
                  aria-hidden="true"
                  class="invisible text-xs text-(--orpheus-text-muted) group-aria-selected/option:visible"
                >
                  ↵
                </span>
              </div>
            </div>
          </div>

          <p class="micro-label flex items-center gap-4 border-t border-(--orpheus-border) px-4 py-2">
            <span>↑↓ move</span>
            <span>↵ open</span>
            <span>esc close</span>
            <span class="ml-auto">⌘K / Ctrl+K · /</span>
          </p>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CommandPalette">
        const RECENT_KEY = "weworkai:command-palette:recent"
        const RECENT_LIMIT = 5

        const typing = (element) =>
          element.closest?.("input, textarea, select, [contenteditable]:not([contenteditable=false])")

        const readRecent = () => {
          try {
            return JSON.parse(localStorage.getItem(RECENT_KEY)) ?? []
          } catch {
            return []
          }
        }

        export default {
          mounted() {
            this.dialog = this.el.querySelector("#command-palette-dialog")
            this.input = this.el.querySelector("#command-palette-input")
            this.results = this.el.querySelector("#command-palette-results")
            this.opened = false
            // Only the hook opens and closes it: a re-render keeps what it chose.
            this.js().ignoreAttributes(this.dialog, ["hidden"])

            this.onWindowKeydown = (event) => {
              const mod = event.metaKey || event.ctrlKey
              if (mod && event.key.toLowerCase() === "k") {
                event.preventDefault()
                this.opened ? this.close() : this.open()
              } else if (event.key === "/" && !mod && !this.opened && !typing(event.target)) {
                event.preventDefault()
                this.open()
              }
            }
            this.onOpen = () => this.open()
            window.addEventListener("keydown", this.onWindowKeydown)
            window.addEventListener("command-palette:open", this.onOpen)

            this.input.addEventListener("keydown", (event) => this.onInputKeydown(event))
            this.input.addEventListener("input", () => (this.resetActive = true))
            this.dialog.addEventListener("mousedown", (event) => {
              if (event.target === this.dialog) this.close()
            })
            this.results.addEventListener("mousemove", (event) => {
              const option = event.target.closest("[role=option]")
              if (option && option.id !== this.activeId) this.activate(option, false)
            })
            this.results.addEventListener("click", (event) => {
              const option = event.target.closest("[role=option]")
              if (option) this.choose(option)
            })
          },

          updated() {
            const kept = !this.resetActive && this.activeId && document.getElementById(this.activeId)
            this.resetActive = false
            this.activate(kept || this.options()[0])
          },

          destroyed() {
            window.removeEventListener("keydown", this.onWindowKeydown)
            window.removeEventListener("command-palette:open", this.onOpen)
          },

          open() {
            if (this.opened) return
            this.opened = true
            this.returnFocus = document.activeElement
            this.input.value = ""
            this.resetActive = true
            this.pushEventTo(this.el, "open", {recent: readRecent()})
            this.dialog.hidden = false
            this.input.focus()
            this.activate(this.options()[0])
          },

          // Leaving the page needs no "close": the palette goes with it.
          close({leaving = false} = {}) {
            if (!this.opened) return
            this.opened = false
            this.dialog.hidden = true
            if (leaving) return
            this.pushEventTo(this.el, "close", {})
            this.returnFocus?.focus?.()
          },

          options() {
            return [...this.results.querySelectorAll("[role=option]")]
          },

          activate(option, scroll = true) {
            this.activeId = option?.id
            for (const each of this.options()) each.setAttribute("aria-selected", each === option)
            if (!option) return this.input.removeAttribute("aria-activedescendant")
            this.input.setAttribute("aria-activedescendant", option.id)
            if (scroll) option.scrollIntoView({block: "nearest"})
          },

          onInputKeydown(event) {
            const options = this.options()
            const index = options.findIndex((option) => option.id === this.activeId)
            const step = {ArrowDown: 1, ArrowUp: -1}[event.key]

            if (step) {
              event.preventDefault()
              if (options.length) this.activate(options[(index + step + options.length) % options.length])
            } else if (event.key === "Home" || event.key === "End") {
              event.preventDefault()
              this.activate(event.key === "Home" ? options[0] : options.at(-1))
            } else if (event.key === "Enter") {
              event.preventDefault()
              if (options[index]) this.choose(options[index])
            } else if (event.key === "Escape") {
              event.preventDefault()
              this.close()
            } else if (event.key === "Tab") {
              // The palette is modal: focus stays in its field.
              event.preventDefault()
            }
          },

          choose(option) {
            const {href, action, label, kind} = option.dataset
            if (action === "theme") {
              const theme = document.documentElement.dataset.theme === "dark" ? "light" : "dark"
              option.dataset.phxTheme = theme
              option.dispatchEvent(new Event("phx:set-theme", {bubbles: true}))
              return this.close()
            }
            // A page with unsaved work (the workflow editor) may keep the person there.
            if (!window.dispatchEvent(new Event("app:leave", {cancelable: true}))) return
            this.remember({label, href, kind})
            this.close({leaving: true})
            this.js().navigate(href)
          },

          remember(pick) {
            const recent = [pick, ...readRecent().filter((each) => each.href !== pick.href)]
            try {
              localStorage.setItem(RECENT_KEY, JSON.stringify(recent.slice(0, RECENT_LIMIT)))
            } catch {}
          },
        }
      </script>
    </div>
    """
  end
end
