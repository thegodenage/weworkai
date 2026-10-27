defmodule WeworkaiWeb.DashboardLive do
  use WeworkaiWeb, :live_view

  alias Weworkai.Agents
  alias Weworkai.Agents.SessionPoller
  alias Weworkai.Agents.Agent.Role

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: SessionPoller.watch_runs()

    {:ok, assign(socket, page_title: "Dashboard", runs: Agents.active_runs!(), statuses: %{})}
  end

  @impl true
  def handle_params(_params, _url, %{assigns: %{live_action: :new}} = socket) do
    agents = Agents.runnable_agents!()

    {:noreply,
     assign(socket,
       agent_options: Enum.map(agents, &{agent_label(&1), &1.id}),
       form: to_form(Agents.form_to_start_run())
     )}
  end

  def handle_params(_params, _url, socket), do: {:noreply, assign(socket, form: nil)}

  @impl true
  def handle_info({:runs, runs, statuses}, socket) do
    {:noreply, assign(socket, runs: runs, statuses: statuses)}
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("start", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Agent started.")
         |> push_navigate(to: ~p"/dashboard/runs/#{run.id}")}

      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end

  defp tallies(runs, statuses) do
    counts = runs |> Enum.map(&Map.get(statuses, &1.id)) |> Enum.frequencies()

    [
      {"active", "Active runs", length(runs), nil},
      {"working", "Working", Map.get(counts, :working, 0), "blue"},
      {"done", "Done", Map.get(counts, :done, 0), "green"},
      {"failed", "Failed / offline",
       Map.get(counts, :failed, 0) + Map.get(counts, :unreachable, 0), "red"}
    ]
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  defp agent_label(agent) do
    "#{agent.employee.name} · #{Role.label(agent.role)} · #{agent.model}"
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
      <div class="mb-8 flex items-end justify-between gap-4 border-b border-(--orpheus-border) pb-4">
        <div>
          <p class="micro-label mb-1">~/dashboard</p>
          <h1 class="text-2xl font-semibold tracking-tight">Dashboard</h1>
        </div>
        <.button patch={~p"/dashboard/new"} variant="primary" class="btn btn-primary btn-sm">
          <.icon name="hero-play-micro" class="size-4" /> Run agent
        </.button>
      </div>

      <dl
        id="run-tallies"
        class="mb-8 grid grid-cols-2 gap-px border border-(--orpheus-border) bg-(--orpheus-border) sm:grid-cols-4"
      >
        <div
          :for={{key, label, count, tone} <- tallies(@runs, @statuses)}
          id={"tally-#{key}"}
          class="bg-(--orpheus-card) px-4 py-3"
        >
          <dt class="micro-label">{label}</dt>
          <dd class={[
            "mt-1 text-2xl font-semibold tabular-nums",
            tone && ["text-(--tone)", "tone-#{tone}"],
            count == 0 && "opacity-40"
          ]}>
            {pad(count)}
          </dd>
        </div>
      </dl>

      <.section_label count={length(@runs)} class="mb-3">Working agents</.section_label>

      <div id="runs" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
        <.link
          :for={{run, index} <- Enum.with_index(@runs, 1)}
          id={"run-#{run.id}"}
          navigate={~p"/dashboard/runs/#{run.id}"}
          class="orpheus-card flex flex-col transition-[translate,box-shadow,border-color] hover:-translate-x-0.5 hover:-translate-y-0.5 hover:border-(--orpheus-border-strong) hover:shadow-[3px_3px_0_0_var(--hard-shadow)] motion-reduce:hover:translate-none"
        >
          <div class="flex items-center justify-between gap-3 border-b border-dashed border-(--orpheus-border) px-4 py-1.5">
            <span class="micro-label tabular-nums">Run #{pad(index)}</span>
            <.run_status status={Map.get(@statuses, run.id)} />
          </div>
          <div class="flex-1 p-4">
            <div class="mb-3 flex items-start gap-3">
              <.avatar employee={run.agent.employee} class="mt-0.5" />
              <div class="min-w-0 flex-1">
                <p class="truncate text-sm font-semibold">{run.agent.employee.name}</p>
                <p class="text-xs text-(--orpheus-text-muted)">
                  {Role.label(run.agent.role)} · {run.agent.model}{run.agent.effort &&
                    " · #{run.agent.effort}"}
                </p>
              </div>
            </div>
            <p class="line-clamp-2 text-sm text-(--orpheus-text-secondary)">{run.task}</p>
          </div>
          <p class="flex items-center gap-1.5 truncate border-t border-(--orpheus-border) bg-base-200 px-4 py-2 text-xs text-(--orpheus-text-muted)">
            <span class="text-primary">&gt;</span>
            <code class="truncate">{run.folder}</code>
          </p>
        </.link>
      </div>

      <div
        :if={@runs == []}
        class="border border-dashed border-(--orpheus-border-strong) bg-(--orpheus-card) p-10 text-center"
      >
        <p class="micro-label mb-2">[ idle ]</p>
        <p class="text-sm text-(--orpheus-text-muted)">
          No agents are working. Use Run agent to start one.
        </p>
      </div>

      <.modal :if={@form} id="run-modal" on_cancel={JS.patch(~p"/dashboard")}>
        <:title>Run agent</:title>
        <p :if={@agent_options == []} class="text-sm text-error">
          No agent is ready. An agent needs a connector and a model; set them on <.link
            navigate={~p"/employees"}
            class="underline"
          >Employees</.link>.
        </p>
        <.form
          :if={@agent_options != []}
          for={@form}
          id="run-form"
          phx-change="validate"
          phx-submit="start"
        >
          <.input
            field={@form[:agent_id]}
            type="select"
            label="Agent"
            prompt="Choose an agent"
            options={@agent_options}
          />
          <.input
            field={@form[:folder]}
            label="Folder on your computer"
            placeholder="~/Projects/my-repo"
          />
          <p class="-mt-1 mb-2 text-xs text-(--orpheus-text-muted)">
            Must be under the bridge's allowed folders (default ~/Projects).
          </p>
          <.input
            field={@form[:task]}
            type="textarea"
            label="Task"
            rows="6"
            placeholder="What should the agent do?"
          />
          <div class="mt-4 flex justify-end gap-2">
            <.button patch={~p"/dashboard"} class="btn btn-ghost btn-sm">Cancel</.button>
            <.button variant="primary" class="btn btn-primary btn-sm" phx-disable-with="Starting…">
              Start
            </.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  attr :status, :atom, required: true

  def run_status(assigns) do
    ~H"""
    <span class={["orpheus-badge shrink-0", "tone-#{tone(@status)}"]}>{label(@status)}</span>
    """
  end

  defp tone(:working), do: "blue"
  defp tone(:done), do: "green"
  defp tone(:failed), do: "red"
  defp tone(:unreachable), do: "red"
  defp tone(_stopped_ended_or_loading), do: "slate"

  defp label(:working), do: "Working"
  defp label(:done), do: "Done"
  defp label(:failed), do: "Failed"
  defp label(:stopped), do: "Stopped"
  defp label(:ended), do: "Gone"
  defp label(:unreachable), do: "Bridge offline"
  defp label(nil), do: "Checking…"

  @doc "Whether a run with this status will not change any more."
  def final_status?(status), do: status in [:done, :failed, :stopped, :ended]
end
