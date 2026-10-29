defmodule WeworkaiWeb.WorkflowLive do
  @moduledoc """
  The workflow editor (docs/workflows.md, "Editor"): a canvas of blocks and arrows the
  `WorkflowEditor` hook (assets/js/workflow_editor) draws and edits in the browser. The
  server is the source of truth at both ends: it hands the stored graph to the hook on
  mount, checks drafts on the hook's request ("validate") and writes the whole graph on
  "save" through `Workflows.save_graph/2` (problems and all), replying with the stored ids,
  the problems by block and arrow id and the new version, or that it was saved elsewhere
  since. Each save is a version: the history beside the canvas lists them, with the tasks
  on each, and restores an older one as the newest.
  """
  use WeworkaiWeb, :live_view

  alias Weworkai.{Organization, Workflows}
  alias Weworkai.Agents.Agent.Role
  alias Weworkai.Board.Task.Status
  alias Weworkai.Workflows.Graph
  alias Weworkai.Workflows.Node.Color

  # A human block stands for the wait itself, so it is no column a block moves the task to.
  @columns Status.values() -- [:await_human_supervision]

  @role_tones %{
    planner: "violet",
    coder: "blue",
    reviewer: "amber",
    qa: "sky",
    merger: "green",
    custom: "slate"
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Workflows.get_workflow(id) do
      {:ok, workflow} ->
        employees = Organization.list_all_employees!(load: :agent)
        graph = Workflows.params(Workflows.graph!(workflow.id))

        {:ok,
         assign(socket,
           page_title: workflow.name,
           workflow: workflow,
           default?: Workflows.default_workflow!().id == workflow.id,
           agents: Enum.filter(employees, &(&1.kind == :agent and &1.agent)),
           humans: Enum.filter(employees, &(&1.kind == :human)),
           graph: graph,
           problems: Workflows.problems(graph),
           catalog: catalog(employees),
           history_open?: false
         )
         |> assign_versions()}

      {:error, _} ->
        {:ok,
         socket |> put_flash(:error, "Workflow not found.") |> push_navigate(to: ~p"/workflows")}
    end
  end

  # What blocks can name and arrows can say, for the inspector's selects.
  defp catalog(employees) do
    %{
      employees:
        Enum.map(employees, fn employee ->
          %{
            id: employee.id,
            name: employee.name,
            kind: employee.kind,
            role: employee.agent && employee.agent.role,
            title: employee.role
          }
        end),
      roles:
        Enum.map(
          Role.values(),
          &%{value: &1, label: Role.label(&1), outcomes: Graph.outcomes(&1)}
        ),
      columns: Enum.map(@columns, &%{value: &1, label: Status.label(&1)}),
      triage_outcomes: Graph.triage_outcomes(),
      colors: Color.values()
    }
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:reply, %{problems: Workflows.problems(params)}, socket}
  end

  # `version`: the one the editor's graph was drawn from, so a save over a newer one (another
  # tab's) is refused unless the editor sends that newer version.
  def handle_event("save", %{"version" => version} = params, socket) when is_integer(version) do
    case Workflows.save_graph(%{socket.assigns.workflow | version: version}, params) do
      {:ok, %{workflow: workflow, ids: ids, problems: problems}} ->
        {:reply, %{ok: true, ids: ids, problems: problems, version: workflow.version},
         socket |> assign(workflow: workflow) |> assign_versions()}

      {:error, :stale} ->
        {:ok, current} = Workflows.get_workflow(socket.assigns.workflow.id)
        {:reply, %{ok: false, stale: true, version: current.version}, socket}

      {:error, problems} ->
        {:reply, %{ok: false, problems: problems}, socket}
    end
  end

  def handle_event("toggle_history", _params, socket) do
    {:noreply,
     socket |> assign(history_open?: not socket.assigns.history_open?) |> assign_versions()}
  end

  # The editor's graph is drawn once, so it opens afresh on the restored graph.
  def handle_event("restore_version", %{"number" => number}, socket) do
    workflow = Workflows.get_workflow!(socket.assigns.workflow.id)
    version = Workflows.get_version!(workflow.id, String.to_integer(number))

    case Workflows.restore_version(workflow, version) do
      {:ok, %{workflow: saved}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Restored v#{version.number} as v#{saved.version}.")
         |> push_navigate(to: ~p"/workflows/#{workflow.id}")}

      {:error, _stale_or_problems} ->
        {:noreply, put_flash(socket, :error, "v#{version.number} could not be restored.")}
    end
  end

  defp assign_versions(socket) do
    workflow_id = socket.assigns.workflow.id

    assign(socket,
      versions: Workflows.list_versions!(workflow_id),
      pinned: Workflows.pinned_counts(workflow_id)
    )
  end

  defp block_count(version), do: Enum.count(version.graph["nodes"], &(&1["kind"] != "group"))

  defp count(1, noun), do: "1 #{noun}"
  defp count(count, noun), do: "#{count} #{noun}s"

  defp role_tone(role), do: Map.fetch!(@role_tones, role)

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:workflows}
      notifications={@notifications}
      unread_count={@unread_count}
      bleed
    >
      <div class="relative h-full">
        <.version_history
          workflow={@workflow}
          versions={@versions}
          pinned={@pinned}
          open?={@history_open?}
        />
        <div
          id="workflow-editor"
          phx-hook="WorkflowEditor"
          phx-update="ignore"
          data-graph={Jason.encode!(@graph)}
          data-problems={Jason.encode!(@problems)}
          data-catalog={Jason.encode!(@catalog)}
          data-workflow-id={@workflow.id}
          data-version={@workflow.version}
          class="wf-editor flex h-full flex-col"
        >
          <header class="wf-toolbar flex h-14 shrink-0 items-center gap-2 border-b border-(--orpheus-border) bg-base-100 px-3">
            <.link
              id="back-to-workflows"
              navigate={~p"/workflows"}
              class="btn btn-ghost btn-sm btn-square"
              title="All workflows"
              aria-label="All workflows"
            >
              <.icon name="hero-arrow-left-micro" class="size-4" />
            </.link>
            <div class="flex min-w-0 items-center gap-2">
              <h1 id="workflow-name" class="truncate text-base font-semibold tracking-tight">
                {@workflow.name}
              </h1>
              <span :if={@default?} id="workflow-default" class="orpheus-badge tone-violet">
                Default
              </span>
              <.link
                id="workflow-rename"
                navigate={~p"/workflows/#{@workflow.id}/edit"}
                class="btn btn-ghost btn-xs btn-square text-(--orpheus-text-muted)"
                title="Rename the workflow"
                aria-label="Rename the workflow"
              >
                <.icon name="hero-pencil-micro" class="size-3.5" />
              </.link>
              <span
                id="wf-dirty"
                class="wf-dirty hidden items-center gap-1.5 text-xs text-(--orpheus-text-muted)"
                aria-live="polite"
              >
                <span class="size-1.5 rounded-full bg-warning"></span> Unsaved changes
              </span>
            </div>

            <div class="mx-auto flex items-center gap-1" role="toolbar" aria-label="Editing">
              <.tool id="wf-undo" icon="hero-arrow-uturn-left-micro" title="Undo (⌘Z)" />
              <.tool id="wf-redo" icon="hero-arrow-uturn-right-micro" title="Redo (⇧⌘Z)" />
              <span class="mx-1 h-5 w-px bg-(--orpheus-border)"></span>
              <.tool
                id="wf-group"
                icon="hero-rectangle-group-micro"
                title="Group the selected blocks (⌘G)"
              />
              <.tool id="wf-ungroup" icon="hero-squares-2x2-micro" title="Ungroup (⇧⌘G)" />
              <.tool id="wf-duplicate" icon="hero-document-duplicate-micro" title="Duplicate (⌘D)" />
              <.tool id="wf-delete" icon="hero-trash-micro" title="Delete the selection (⌫)" />
            </div>

            <div class="flex items-center gap-2">
              <button
                id="wf-problem-count"
                type="button"
                class="wf-problem-count hidden items-center gap-1.5"
                title="Show the problems"
              >
                <.icon name="hero-exclamation-circle-micro" class="size-4" />
                <span data-count></span>
              </button>
              <button
                id="wf-save"
                type="button"
                class="btn btn-primary btn-sm min-w-20 shadow-sm shadow-primary/30 transition-transform active:scale-[0.98]"
                title="Save (⌘S)"
              >
                <.icon name="hero-check-micro" class="size-4" />
                <span data-label>Save</span>
              </button>
              <%!-- Room for the version chip, which floats here from outside the ignored editor. --%>
              <span class="wf-versions-slot" aria-hidden="true"></span>
            </div>
          </header>

          <div class="flex min-h-0 flex-1">
            <aside
              id="wf-palette"
              aria-label="Blocks"
              class="wf-palette flex w-60 shrink-0 flex-col border-r border-(--orpheus-border) bg-base-100"
            >
              <div class="p-3 pb-2">
                <label class="input input-sm flex w-full items-center gap-2">
                  <.icon
                    name="hero-magnifying-glass-micro"
                    class="size-4 text-(--orpheus-text-muted)"
                  />
                  <input
                    id="wf-palette-search"
                    type="search"
                    placeholder="Search blocks"
                    aria-label="Search blocks"
                    class="grow"
                  />
                </label>
              </div>
              <div id="wf-palette-list" class="min-h-0 flex-1 overflow-y-auto px-3 pb-4">
                <.palette_section id="roles" title="Roles" count={length(Role.values())}>
                  <.palette_item
                    :for={role <- Role.values()}
                    id={"palette-role-#{role}"}
                    kind="agent"
                    agent_role={role}
                    label={Role.label(role)}
                    subtitle={"Any #{String.downcase(Role.label(role))}"}
                    tone={role_tone(role)}
                    icon="hero-cpu-chip-micro"
                  />
                </.palette_section>

                <.palette_section
                  :if={@agents != []}
                  id="agents"
                  title="Agents"
                  count={length(@agents)}
                >
                  <.palette_item
                    :for={agent <- @agents}
                    id={"palette-agent-#{agent.id}"}
                    kind="agent"
                    employee_id={agent.id}
                    label={agent.name}
                    subtitle={Role.label(agent.agent.role)}
                    tone={role_tone(agent.agent.role)}
                    avatar={initials(agent.name)}
                  />
                </.palette_section>

                <.palette_section id="humans" title="Humans" count={length(@humans) + 1}>
                  <.palette_item
                    id="palette-human-any"
                    kind="human"
                    label="Review"
                    subtitle="Any human"
                    tone="green"
                    icon="hero-user-micro"
                  />
                  <.palette_item
                    :for={human <- @humans}
                    id={"palette-human-#{human.id}"}
                    kind="human"
                    employee_id={human.id}
                    label={human.name}
                    subtitle={human.role}
                    tone="green"
                    avatar={initials(human.name)}
                  />
                </.palette_section>

                <.palette_section id="columns" title="Kanban columns" count={length(columns())}>
                  <.palette_item
                    :for={status <- columns()}
                    id={"palette-column-#{status}"}
                    kind="column"
                    column_status={status}
                    label={Status.label(status)}
                    subtitle="Moves the task here"
                    tone="slate"
                    icon="hero-view-columns-micro"
                  />
                </.palette_section>

                <.palette_section id="structure" title="Structure" count={2}>
                  <.palette_item
                    id="palette-group"
                    kind="group"
                    label="Group"
                    subtitle="Runs the blocks inside it"
                    tone="violet"
                    icon="hero-rectangle-group-micro"
                  />
                  <.palette_item
                    id="palette-triage"
                    kind="triage"
                    label="Triage"
                    subtitle="Routes by worst severity"
                    tone="amber"
                    icon="hero-funnel-micro"
                  />
                </.palette_section>
                <p class="wf-palette-empty hidden px-1 text-xs text-(--orpheus-text-muted)">
                  No block matches.
                </p>
              </div>
            </aside>

            <div
              id="wf-viewport"
              class="wf-viewport relative min-w-0 flex-1 overflow-hidden"
              tabindex="-1"
              role="region"
              aria-label="Workflow canvas"
            >
              <div class="wf-world" data-world>
                <div class="wf-groups" data-groups></div>
                <svg class="wf-edges" data-edges aria-hidden="true"></svg>
                <div class="wf-nodes" data-nodes></div>
                <div class="wf-labels" data-labels></div>
                <svg class="wf-guides" data-guides aria-hidden="true"></svg>
              </div>
              <div class="wf-rubber hidden" data-rubber></div>
              <div id="wf-banner" class="wf-banner hidden" role="status" aria-live="polite"></div>
              <div
                id="wf-empty"
                class="wf-empty pointer-events-none absolute inset-0 hidden items-center justify-center"
              >
                <div class="max-w-sm rounded-xl border border-dashed border-(--orpheus-border) bg-(--orpheus-card)/80 px-8 py-7 text-center shadow-sm backdrop-blur">
                  <span class="mx-auto mb-3 flex size-10 items-center justify-center rounded-full bg-primary/10 text-primary">
                    <.icon name="hero-cursor-arrow-rays" class="size-5" />
                  </span>
                  <p class="font-medium">Drag a planner here to start</p>
                  <p class="mt-1 text-sm text-(--orpheus-text-muted)">
                    The first block is where every task starts. Then drag from a block's dot onto another to connect them, or drop a new block right onto a dot.
                  </p>
                  <div class="pointer-events-auto mt-4 flex justify-center gap-2">
                    <button id="wf-empty-planner" type="button" class="btn btn-primary btn-sm">
                      <.icon name="hero-plus-micro" class="size-4" /> Add a planner
                    </button>
                    <button id="wf-empty-search" type="button" class="btn btn-ghost btn-sm">
                      <.icon name="hero-magnifying-glass-micro" class="size-4" /> Find a block
                    </button>
                  </div>
                  <p class="mt-3 text-xs text-(--orpheus-text-muted)">
                    Tip: double-click the canvas to add a block where you clicked.
                  </p>
                </div>
              </div>
              <div class="wf-zoom absolute bottom-4 left-4 flex items-center gap-0.5 rounded-lg border border-(--orpheus-border) bg-(--orpheus-card) p-0.5 shadow-sm">
                <.tool id="wf-zoom-out" icon="hero-minus-micro" title="Zoom out (−)" />
                <button
                  id="wf-zoom-reset"
                  type="button"
                  class="btn btn-ghost btn-xs w-14 font-mono text-xs tabular-nums"
                  title="Zoom to 100%"
                >
                  100%
                </button>
                <.tool id="wf-zoom-in" icon="hero-plus-micro" title="Zoom in (+)" />
                <span class="mx-0.5 h-4 w-px bg-(--orpheus-border)"></span>
                <.tool id="wf-fit" icon="hero-arrows-pointing-out-micro" title="Fit to view (⇧1)" />
              </div>
              <div class="wf-hint pointer-events-none absolute right-4 bottom-4 hidden rounded-md bg-(--orpheus-card) px-2.5 py-1.5 text-xs text-(--orpheus-text-muted) shadow-sm sm:block">
                Drag or scroll to pan · ⇧ drag to select · pinch or ⌘ scroll to zoom
              </div>
              <div class="wf-menu hidden" data-menu role="menu"></div>
              <div
                id="wf-quick-add"
                class="wf-quick hidden"
                data-quick
                role="dialog"
                aria-label="Add a block"
              >
              </div>
            </div>

            <aside
              id="wf-inspector"
              aria-label="Inspector"
              class="wf-inspector w-76 shrink-0 overflow-y-auto border-l border-(--orpheus-border) bg-base-100"
            >
            </aside>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :workflow, :map, required: true
  attr :versions, :list, required: true
  attr :pinned, :map, required: true
  attr :open?, :boolean, required: true

  # Floats over the toolbar's end, on the slot kept for it: the editor under it is drawn
  # once (phx-update="ignore"), so this stays the server's to render.
  defp version_history(assigns) do
    ~H"""
    <div id="wf-versions" class="wf-versions">
      <button
        id="wf-versions-toggle"
        type="button"
        phx-click="toggle_history"
        aria-expanded={to_string(@open?)}
        aria-controls="wf-versions-list"
        class="wf-versions-toggle"
        title="Versions: every save keeps the graph it saved"
      >
        <.icon name="hero-clock-micro" class="size-3.5 shrink-0" />
        <span id="wf-version" class="font-semibold text-base-content">v{@workflow.version}</span>
        <.icon
          name="hero-chevron-down-micro"
          class={["size-3.5 shrink-0 transition-transform", @open? && "rotate-180"]}
        />
      </button>
      <ol :if={@open?} id="wf-versions-list" class="wf-versions-list hard-shadow">
        <li
          :for={version <- @versions}
          id={"wf-version-#{version.number}"}
          class="wf-version-row"
          data-current={version.number == @workflow.version}
        >
          <div class="flex items-baseline gap-2">
            <span class="font-semibold text-base-content">v{version.number}</span>
            <span :if={version.number == @workflow.version} class="orpheus-badge tone-accent">
              Current
            </span>
            <span :if={version.problem_count > 0} class="orpheus-badge tone-red">
              {count(version.problem_count, "problem")}
            </span>
            <time
              class="ml-auto text-(--orpheus-text-muted)"
              datetime={DateTime.to_iso8601(version.inserted_at)}
            >
              {Calendar.strftime(version.inserted_at, "%b %-d %H:%M")}
            </time>
          </div>
          <div class="flex items-center gap-2 text-(--orpheus-text-muted)">
            <span>{count(block_count(version), "block")}</span>
            <span aria-hidden="true">·</span>
            <span id={"wf-version-#{version.number}-tasks"}>
              {count(Map.get(@pinned, version.number, 0), "task")} on it
            </span>
            <button
              :if={version.number != @workflow.version}
              id={"wf-version-#{version.number}-restore"}
              type="button"
              phx-click="restore_version"
              phx-value-number={version.number}
              data-confirm={"Save v#{version.number}'s graph as v#{@workflow.version + 1}? Tasks keep the version they run; unsaved edits here stay as a draft."}
              class="wf-version-restore ml-auto"
            >
              Restore
            </button>
          </div>
        </li>
      </ol>
    </div>
    """
  end

  defp columns, do: @columns

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true

  defp tool(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      title={@title}
      aria-label={@title}
      class="btn btn-ghost btn-sm btn-square text-(--orpheus-text-secondary) transition-colors hover:text-base-content disabled:opacity-30"
    >
      <.icon name={@icon} class="size-4" />
    </button>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, required: true
  slot :inner_block, required: true

  # Collapsible, with its header sticking to the top while its items scroll by; the editor
  # remembers which are closed and opens every one with a match while searching.
  defp palette_section(assigns) do
    ~H"""
    <details id={"wf-palette-#{@id}"} class="wf-palette-section" data-section={@id} open>
      <summary class="wf-palette-heading">
        <.icon name="hero-chevron-right-micro" class="wf-palette-chevron size-3.5" />
        <span class="flex-1">{@title}</span>
        <span class="wf-palette-count" data-count>{@count}</span>
      </summary>
      <div class="space-y-1 pt-0.5 pb-3">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :kind, :string, required: true
  attr :label, :string, required: true
  attr :subtitle, :string, default: nil
  attr :tone, :string, required: true
  attr :employee_id, :string, default: nil
  attr :agent_role, :atom, default: nil
  attr :column_status, :atom, default: nil
  attr :avatar, :string, default: nil
  attr :icon, :string, default: nil

  defp palette_item(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class={["wf-palette-item", "tone-#{@tone}"]}
      data-palette
      data-kind={@kind}
      data-label={@label}
      data-employee-id={@employee_id}
      data-agent-role={@agent_role}
      data-column-status={@column_status}
      data-search={String.downcase("#{@label} #{@subtitle} #{@kind}")}
      title="Drag onto the canvas, or press Enter to add it"
      aria-label={"Add #{@label} (#{@subtitle || @kind})"}
    >
      <span :if={@avatar} class="wf-avatar">{@avatar}</span>
      <span :if={@icon} class="wf-avatar wf-avatar-icon"><.icon name={@icon} class="size-3.5" /></span>
      <span class="min-w-0 flex-1 text-left">
        <span class="block truncate text-sm leading-tight font-medium">{@label}</span>
        <span :if={@subtitle} class="block truncate text-xs leading-tight text-(--orpheus-text-muted)">
          {@subtitle}
        </span>
      </span>
      <.icon name="hero-bars-2-micro" class="wf-grip size-3.5" />
    </button>
    """
  end
end
