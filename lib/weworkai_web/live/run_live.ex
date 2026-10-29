defmodule WeworkaiWeb.RunLive do
  use WeworkaiWeb, :live_view

  alias Weworkai.Agents
  alias Weworkai.Agents.SessionPoller
  alias Weworkai.Agents.Agent.Role
  alias Weworkai.Audit.Timeline
  alias WeworkaiWeb.DashboardLive

  import WeworkaiWeb.UsageComponents, only: [usage: 1]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Agents.get_run(id, load: [:usage, agent: [:employee, connector_link: :connector]]) do
      {:ok, run} ->
        {:ok,
         assign(socket,
           page_title: run.agent.employee.name,
           run: run,
           status: watch(socket, run),
           error: nil,
           output_hash: nil,
           tools: nil
         )}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Run not found.")
         |> push_navigate(to: ~p"/dashboard")}
    end
  end

  # Nil until the first poll answers ("Checking…"). Finished runs are polled once, for their log.
  defp watch(socket, %{agent: %{connector_link: %{connector: connector}}} = run) do
    if connected?(socket), do: SessionPoller.watch_session(connector, run.session_id)
    nil
  end

  defp watch(_socket, _run), do: :ended

  @impl true
  def handle_info({:session, id, {:ok, session}}, socket) do
    if DashboardLive.final_status?(session.status), do: SessionPoller.unwatch_session(id)
    hash = :erlang.phash2(session.output)

    socket =
      socket
      |> assign(status: session.status, error: nil, tools: Map.get(session, :tools))
      |> load_usage()

    if hash == socket.assigns.output_hash do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(output_hash: hash)
       |> push_event("terminal:output", %{output: session.output})}
    end
  end

  def handle_info({:session, id, {:error, :not_found}}, socket) do
    SessionPoller.unwatch_session(id)
    {:noreply, assign(socket, status: :ended)}
  end

  def handle_info({:session, _id, {:error, message}}, socket) do
    {:noreply, assign(socket, status: :unreachable, error: message)}
  end

  # The scheduler records a run's usage when it consumes the finished run, which may be a
  # poll after this page saw it finish.
  defp load_usage(%{assigns: %{run: %{usage: %{}}}} = socket), do: socket

  defp load_usage(%{assigns: %{run: run, status: status}} = socket) do
    if DashboardLive.final_status?(status),
      do: assign(socket, run: Ash.load!(run, :usage)),
      else: socket
  end

  @impl true
  def handle_event("stop", _params, socket) do
    case Agents.stop_run(socket.assigns.run) do
      {:ok, _run} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{socket.assigns.run.agent.employee.name}'s run closed.")
         |> push_navigate(to: ~p"/dashboard")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, Exception.message(error))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:dashboard}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <div :if={assigns[:run]}>
        <.link
          navigate={~p"/dashboard"}
          class="mb-4 inline-flex items-center gap-1 text-sm text-(--orpheus-text-muted) hover:text-base-content"
        >
          <.icon name="hero-arrow-left-micro" class="size-4" /> Dashboard
        </.link>

        <div class="mb-4 flex flex-wrap items-start justify-between gap-4">
          <div class="min-w-0">
            <div class="flex items-center gap-3">
              <h1 class="text-2xl font-semibold tracking-tight">{@run.agent.employee.name}</h1>
              <DashboardLive.run_status status={@status} />
            </div>
            <p class="mt-1 text-sm text-(--orpheus-text-muted)">
              {Role.label(@run.agent.role)} · {@run.agent.model}{@run.agent.effort &&
                " · #{@run.agent.effort}"} · <code>{@run.folder}</code>
            </p>
            <p :if={@run.usage} id="run-usage" class="mt-1 text-(--orpheus-text-secondary)">
              <.usage usage={@run.usage} />
              <span class="font-mono text-xs">
                · {@run.usage.turns} turns · {Timeline.duration(@run.usage.duration_ms)}
              </span>
            </p>
          </div>
          <.button
            :if={!DashboardLive.final_status?(@status)}
            id="stop-run"
            phx-click="stop"
            data-confirm="Stop this agent? Its conversation is kept by Claude Code."
            class="btn btn-sm btn-error btn-outline"
            phx-disable-with="Stopping…"
          >
            <.icon name="hero-stop-micro" class="size-4" /> Stop
          </.button>
          <.button
            :if={DashboardLive.final_status?(@status) and is_nil(@run.stopped_at)}
            id="dismiss-run"
            phx-click="stop"
            class="btn btn-sm btn-ghost"
            phx-disable-with="Dismissing…"
          >
            <.icon name="hero-archive-box-micro" class="size-4" /> Dismiss
          </.button>
        </div>

        <p class="mb-3 line-clamp-3 text-sm text-(--orpheus-text-secondary)">{@run.task}</p>
        <p :if={@error} class="mb-3 text-sm text-error">{@error}</p>

        <div class="overflow-x-auto rounded-lg border border-(--orpheus-border) bg-[#0c0c0c] p-3">
          <div id="terminal" phx-hook="Terminal" phx-update="ignore"></div>
        </div>

        <section :if={@tools} id="run-tools" class="mt-4 grid gap-3 text-sm md:grid-cols-3">
          <div id="run-tool-calls" class="rounded-lg border border-(--orpheus-border) p-3">
            <h3 class="mb-2 text-xs font-medium uppercase tracking-wide text-(--orpheus-text-muted)">
              Tool calls
            </h3>
            <p :if={@tools.calls == %{}} class="text-(--orpheus-text-muted)">None yet.</p>
            <ul class="flex flex-wrap gap-1.5">
              <li
                :for={{name, count} <- Enum.sort_by(@tools.calls, fn {_name, count} -> -count end)}
                class="rounded bg-base-300 px-1.5 py-0.5 font-mono text-xs"
              >
                {name} ×{count}
              </li>
            </ul>
          </div>
          <div id="run-host-tools" class="rounded-lg border border-(--orpheus-border) p-3">
            <h3 class="mb-2 text-xs font-medium uppercase tracking-wide text-(--orpheus-text-muted)">
              Host tools
            </h3>
            <p :if={@tools.host_tools == []} class="text-(--orpheus-text-muted)">
              None: no host login reached this run.
            </p>
            <p :if={@tools.host_tools != []} class="mb-1 text-xs text-(--orpheus-text-secondary)">
              Had {Enum.join(@tools.host_tools, ", ")}
            </p>
            <ul class="space-y-1">
              <li
                :for={{call, index} <- Enum.with_index(@tools.host_calls)}
                id={"run-host-call-#{index}"}
                class="truncate font-mono text-xs"
              >
                {call.command}
              </li>
            </ul>
          </div>
          <div id="run-skills" class="rounded-lg border border-(--orpheus-border) p-3">
            <h3 class="mb-2 text-xs font-medium uppercase tracking-wide text-(--orpheus-text-muted)">
              Skills
            </h3>
            <p :if={@tools.skills == []} class="text-(--orpheus-text-muted)">None available.</p>
            <ul class="flex flex-wrap gap-1.5">
              <li
                :for={skill <- @tools.skills}
                class={[
                  "rounded px-1.5 py-0.5 text-xs transition-colors",
                  if(skill in @tools.skills_used,
                    do: "bg-primary/20 text-primary",
                    else: "bg-base-300 text-(--orpheus-text-secondary)"
                  )
                ]}
              >
                {skill}
              </li>
            </ul>
          </div>
        </section>
        <p class="mt-2 text-xs text-(--orpheus-text-muted)">
          Read-only. The run's conversation <code>{@run.claude_session_id}</code>
          (folder <code>{@run.folder}</code>) lives in the agent containers' volume;
          docs/workflow.md shows how to continue it yourself.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
