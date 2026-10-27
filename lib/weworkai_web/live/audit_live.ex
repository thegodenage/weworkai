defmodule WeworkaiWeb.AuditLive do
  @moduledoc """
  Audit: every task, and for the one picked its timeline (`Weworkai.Audit.Timeline`):
  which agent worked on which block, for how long, and where the task waited on people.
  A task in the works keeps its chart growing.
  """
  use WeworkaiWeb, :live_view

  alias Weworkai.Agents
  alias Weworkai.Agents.Usage
  alias Weworkai.Audit.Timeline
  alias Weworkai.Board

  import WeworkaiWeb.TaskComponents
  import WeworkaiWeb.TimelineComponents
  import WeworkaiWeb.UsageComponents, only: [usage_table: 1]

  # How often a task in the works redraws its chart between changes, so "now" moves on.
  @refresh_ms 5_000

  @spend_days 7

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Weworkai.PubSub, "tasks")
      :timer.send_interval(@refresh_ms, :refresh)
    end

    {:ok,
     assign(socket,
       page_title: "Audit",
       tasks: Enum.sort_by(Board.list_tasks!(), & &1.updated_at, {:desc, DateTime}),
       query: "",
       task: nil,
       timeline: nil,
       group: :block,
       selected: nil,
       spend: spend()
     )}
  end

  defp spend do
    DateTime.utc_now()
    |> DateTime.add(-@spend_days, :day)
    |> Agents.usage_since!()
    |> Usage.by_agent()
  end

  defp spend_title, do: "Spend per agent · last #{@spend_days} days"

  @impl true
  def handle_params(params, _url, socket) do
    group = if params["by"] == "agent", do: :agent, else: :block
    {:noreply, socket |> assign(group: group, selected: nil) |> open(params["id"])}
  end

  defp open(socket, nil), do: assign(socket, page_title: "Audit", task: nil, timeline: nil)

  defp open(socket, id) do
    case Board.get_task(id) do
      {:ok, task} ->
        socket |> assign(page_title: "Audit · #{task.title}", task: task) |> build()

      {:error, _} ->
        socket |> put_flash(:error, "Task not found.") |> push_patch(to: ~p"/audit")
    end
  end

  defp build(%{assigns: %{task: task, group: group}} = socket),
    do: assign(socket, timeline: Timeline.build(task, group))

  @impl true
  def handle_event("search", %{"query" => query}, socket),
    do: {:noreply, assign(socket, query: query)}

  # Clicking the selected bar again closes its details.
  def handle_event("select_bar", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected: if(socket.assigns.selected == id, do: nil, else: id))}
  end

  # A task or one of its jobs changed: its row goes to the top, its chart is drawn again.
  @impl true
  def handle_info({:task_updated, %{id: id}}, socket) do
    case Board.get_task(id) do
      {:ok, task} ->
        {:noreply,
         socket
         |> update(:tasks, &[task | Enum.reject(&1, fn listed -> listed.id == id end)])
         |> assign(spend: spend())
         |> refresh(task)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({:task_deleted, %{id: id}}, socket) do
    socket = update(socket, :tasks, &Enum.reject(&1, fn task -> task.id == id end))

    if socket.assigns.task && socket.assigns.task.id == id do
      {:noreply,
       socket |> put_flash(:error, "This task was deleted.") |> push_patch(to: ~p"/audit")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh, %{assigns: %{task: %{}, timeline: %{live?: true}}} = socket),
    do: {:noreply, build(socket)}

  def handle_info(:refresh, socket), do: {:noreply, socket}

  defp refresh(%{assigns: %{task: %{id: id}}} = socket, %{id: id} = task),
    do: socket |> assign(task: task) |> build()

  defp refresh(socket, _task), do: socket

  defp visible(tasks, query) do
    case String.downcase(String.trim(query)) do
      "" -> tasks
      query -> Enum.filter(tasks, &String.contains?(String.downcase(&1.title), query))
    end
  end

  defp task_path(id, :agent), do: ~p"/audit/#{id}?by=agent"
  defp task_path(id, :block), do: ~p"/audit/#{id}"

  defp ago(at),
    do: "#{Timeline.duration(max(DateTime.diff(DateTime.utc_now(), at, :millisecond), 0))} ago"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:audit}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <div class="mb-6">
        <h1 class="text-2xl font-semibold tracking-tight">Audit</h1>
        <p class="mt-1 text-sm text-(--orpheus-text-muted)">
          Pick a task to see which agent worked on what, and where its time went.
        </p>
      </div>

      <div class="grid items-start gap-6 lg:grid-cols-[18rem_minmax(0,1fr)]">
        <section
          id="audit-tasks"
          aria-label="Tasks"
          class="orpheus-card flex flex-col overflow-hidden lg:sticky lg:top-8 lg:max-h-[calc(100vh-4rem)]"
        >
          <form
            id="audit-search"
            phx-change="search"
            phx-submit="search"
            class="border-b border-(--orpheus-border) p-2"
          >
            <input
              id="audit-search-query"
              type="search"
              name="query"
              value={@query}
              placeholder="Find a task…"
              aria-label="Find a task"
              autocomplete="off"
              phx-debounce="150"
              class="input input-sm w-full"
            />
          </form>
          <ul id="audit-task-list" class="flex-1 space-y-0.5 overflow-y-auto p-1">
            <li :for={task <- visible(@tasks, @query)}>
              <.link
                id={"audit-task-#{task.id}"}
                patch={task_path(task.id, @group)}
                aria-current={@task && @task.id == task.id && "page"}
                class="audit-task flex flex-col gap-1.5 rounded-md px-3 py-2 transition-colors hover:bg-(--orpheus-hover)"
              >
                <span class="flex items-center gap-2">
                  <span class="min-w-0 flex-1 truncate text-sm font-medium">{task.title}</span>
                  <.spinner
                    :if={task.activity && task.activity.state == :running}
                    class="size-2.5 text-primary"
                  />
                </span>
                <span class="flex items-center gap-2 text-xs text-(--orpheus-text-muted)">
                  <.status_badge status={task.status} />
                  <span class="truncate">{ago(task.updated_at)}</span>
                </span>
              </.link>
            </li>
            <li
              :if={visible(@tasks, @query) == []}
              id="audit-no-tasks"
              class="px-3 py-8 text-center text-sm text-(--orpheus-text-muted)"
            >
              {if @tasks == [], do: "No tasks yet.", else: "No task matches."}
            </li>
          </ul>
        </section>

        <%= if @task do %>
          <section id="audit-timeline" aria-labelledby="audit-title" class="min-w-0 space-y-4">
            <header class="flex flex-wrap items-center gap-3">
              <h2 id="audit-title" class="min-w-0 truncate text-lg font-semibold">{@task.title}</h2>
              <.status_badge status={@task.status} />
              <.agent_activity :if={@task.activity} id="audit-working" activity={@task.activity} />
              <div class="ml-auto flex items-center gap-2">
                <nav aria-label="Lanes" class="flex rounded-lg bg-base-200 p-0.5 text-xs">
                  <.group_link
                    id="audit-by-block"
                    patch={task_path(@task.id, :block)}
                    active={@group == :block}
                  >
                    Blocks
                  </.group_link>
                  <.group_link
                    id="audit-by-agent"
                    patch={task_path(@task.id, :agent)}
                    active={@group == :agent}
                  >
                    Agents
                  </.group_link>
                </nav>
                <.link
                  id="audit-open-task"
                  navigate={~p"/tasks/#{@task.id}"}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" /> Open task
                </.link>
              </div>
            </header>

            <%= if @timeline.from do %>
              <.stats totals={@timeline.totals} live?={@timeline.live?} />
              <.gantt timeline={@timeline} selected={@selected} />
              <.legend />
              <%= if bar = Timeline.bar(@timeline, @selected) do %>
                <.bar_details bar={bar} />
              <% end %>
              <.breakdown rows={@timeline.breakdown} />
            <% else %>
              <div
                id="audit-timeline-empty"
                class="orpheus-card px-6 py-12 text-center text-sm text-(--orpheus-text-muted)"
              >
                Nothing happened on this task yet. Its timeline starts when it moves to Todo.
              </div>
            <% end %>
          </section>
        <% else %>
          <div class="min-w-0 space-y-4">
            <.usage_table
              :if={@spend != []}
              id="audit-spend"
              title={spend_title()}
              rows={@spend}
            />
            <div
              id="audit-empty"
              class="orpheus-card flex flex-col items-center justify-center gap-2 px-6 py-16 text-center"
            >
              <.icon name="hero-chart-bar-square" class="size-8 text-(--orpheus-text-muted)" />
              <p class="font-medium">Pick a task</p>
              <p class="max-w-sm text-sm text-(--orpheus-text-muted)">
                Its timeline shows each agent's runs per workflow block, queued and running, and the steps people took between them.
              </p>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :patch, :string, required: true
  attr :active, :boolean, required: true
  slot :inner_block, required: true

  defp group_link(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@patch}
      aria-current={@active && "true"}
      class={[
        "rounded-md px-3 py-1 transition-colors",
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
