defmodule WeworkaiWeb.TaskComponents do
  @moduledoc "Badges and controls a task shows on the board and in its own view."
  use Phoenix.Component

  import WeworkaiWeb.CoreComponents, only: [icon: 1]

  alias Weworkai.Agents.Errors.NotRunnable
  alias Weworkai.Board.Errors.{NoAgent, NoWorktree}
  alias Weworkai.Workflows.Errors.{Refused, WorktreeRefused}
  alias Weworkai.Board.Task
  alias Weworkai.Recurring
  alias Weworkai.Board.Task.{Activity, Stage, Status}
  alias Weworkai.ErrorText
  alias Phoenix.LiveView.JS

  @tones %{
    backlog: "slate",
    todo: "sky",
    in_progress: "blue",
    review: "violet",
    await_human_supervision: "amber",
    done: "green",
    canceled: "red"
  }

  def status_tone(status), do: Map.fetch!(@tones, status)

  attr :status, :atom, required: true
  attr :rest, :global

  def status_badge(assigns) do
    ~H"""
    <span class={["orpheus-badge", "tone-#{status_tone(@status)}"]} data-status={@status} {@rest}>
      {Status.label(@status)}
    </span>
    """
  end

  attr :stage, :atom, required: true
  attr :rest, :global

  def stage_badge(assigns) do
    ~H"""
    <span data-stage={@stage} class="orpheus-badge tone-blue" {@rest}>{Stage.label(@stage)}</span>
    """
  end

  @doc "[BLOCKED] while blockers are open (`Task.open_blocker_titles`); hover names them."
  attr :titles, :list, required: true
  attr :rest, :global

  def blocked_badge(assigns) do
    ~H"""
    <span
      class="orpheus-badge tone-red gap-1"
      title={"Blocked by " <> Enum.join(@titles, ", ")}
      {@rest}
    >
      <.icon name="hero-lock-closed-micro" class="size-3" /> Blocked
    </span>
    """
  end

  @doc "Sub-tasks done of those not canceled, as [2/5] over a hairline meter."
  attr :done, :integer, required: true
  attr :total, :integer, required: true
  attr :rest, :global

  def subtask_progress(assigns) do
    ~H"""
    <span
      class={["orpheus-badge gap-1.5", if(@done == @total, do: "tone-green", else: "tone-slate")]}
      title={"#{@done} of #{@total} sub-tasks done"}
      {@rest}
    >
      <.icon name="hero-rectangle-stack-micro" class="size-3" />
      <span class="tabular-nums">{@done}/{@total}</span>
      <span class="relative h-[3px] w-8 bg-(--orpheus-border)" aria-hidden="true">
        <span
          class="absolute inset-y-0 left-0 bg-(--tone) transition-[width] duration-300"
          style={"width: #{if @total == 0, do: 0, else: div(@done * 100, @total)}%"}
        ></span>
      </span>
    </span>
    """
  end

  attr :tag, :string, required: true
  attr :rest, :global

  @doc "One of a task's tags; a cron's own (CRON) stands out."
  def task_tag(assigns) do
    assigns = assign(assigns, cron?: assigns.tag == Task.cron_tag())

    ~H"""
    <span
      data-tag={@tag}
      class={["orpheus-badge", if(@cron?, do: "tone-sky", else: "tone-slate")]}
      {@rest}
    >
      <.icon :if={@cron?} name="hero-arrow-path-micro" class="size-3" />
      {@tag}
    </span>
    """
  end

  attr :at, DateTime, required: true
  attr :timezone, :string, default: nil
  attr :rest, :global

  @doc "When the cron that created the task was due, on the cron's clock."
  def cron_time(assigns) do
    ~H"""
    <span
      class="inline-flex items-center gap-1 font-mono text-[11px] text-(--orpheus-text-muted)"
      title={"Scheduled run (#{@timezone || "Etc/UTC"})"}
      {@rest}
    >
      <.icon name="hero-clock-micro" class="size-3" />
      {Recurring.local_time(@at, @timezone)}
    </span>
    """
  end

  @doc "The workflow block a task is on (`Task.current_node`)."
  attr :block, :map, required: true
  attr :rest, :global

  def block_badge(assigns) do
    ~H"""
    <span class="orpheus-badge tone-slate gap-1" title="Workflow block" {@rest}>
      <.icon name="hero-squares-2x2-micro" class="size-3" />
      <span class="max-w-40 truncate">{@block.label}</span>
    </span>
    """
  end

  @doc """
  "Continue → <default>" with a menu of the other targets (`Board.continue_targets/1`:
  the blocks of the task's workflow, and "done").
  Pushes a `"continue"` event with `target` (and `id` when given). Asks first while an
  agent works on the task, since continuing stops it.
  """
  attr :id, :string, required: true
  attr :targets, :list, required: true
  attr :working?, :boolean, default: false
  attr :task_id, :string, default: nil
  attr :size, :string, default: "btn-sm"

  def continue_control(assigns) do
    assigns =
      assign(assigns,
        confirm: assigns.working? && "An agent is working on this task. Stop it and continue?"
      )

    ~H"""
    <div id={"#{@id}-control"} class="relative inline-flex">
      <button
        id={@id}
        type="button"
        phx-click="continue"
        phx-value-target={hd(@targets).id}
        phx-value-id={@task_id}
        data-confirm={@confirm}
        phx-disable-with="Continuing…"
        title="Push the task on: stops whatever runs on it, then starts this step"
        class={["btn btn-outline rounded-r-none", @size]}
      >
        <.icon name="hero-forward-micro" class="size-4" /> Continue
        <span class="font-normal text-(--orpheus-text-muted)">→ {hd(@targets).label}</span>
      </button>
      <button
        id={"#{@id}-toggle"}
        type="button"
        aria-label="Choose where to continue"
        aria-haspopup="menu"
        phx-click={JS.toggle(to: "##{@id}-menu")}
        class={["btn btn-outline btn-square rounded-l-none border-l-0", @size]}
      >
        <.icon name="hero-chevron-down-micro" class="size-4" />
      </button>
      <ul
        id={"#{@id}-menu"}
        role="menu"
        phx-click-away={JS.hide(to: "##{@id}-menu")}
        class="orpheus-card absolute top-full right-0 z-30 mt-1 hidden w-52 p-1 shadow-xl"
      >
        <li :for={target <- @targets} role="none">
          <button
            id={"#{@id}-#{target.id}"}
            type="button"
            role="menuitem"
            phx-click="continue"
            phx-value-target={target.id}
            phx-value-id={@task_id}
            data-confirm={@confirm}
            class="flex w-full items-center gap-2 rounded px-3 py-1.5 text-left text-sm transition-colors hover:bg-(--orpheus-hover)"
          >
            <.icon name={target_icon(target.id)} class="size-4 text-(--orpheus-text-muted)" />
            <span class="truncate">{target.label}</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp target_icon("done"), do: "hero-check-micro"
  defp target_icon(_block), do: "hero-arrow-uturn-right-micro"

  @doc "What a refused Continue tells the human."
  def continue_error(%Ash.Error.Invalid{errors: [%type{} | _]} = error)
      when type in [NotRunnable, NoAgent, NoWorktree, Refused, WorktreeRefused],
      do: ErrorText.readable(error)

  def continue_error(_stale), do: "This task changed meanwhile. Look again, then continue."

  attr :class, :any, default: nil
  attr :rest, :global

  def needs_you(assigns) do
    ~H"""
    <span class={["orpheus-badge tone-amber gap-1.5 font-semibold", @class]} {@rest}>
      <span class="relative flex size-1.5">
        <span class="absolute inline-flex size-full bg-(--tone) opacity-75 motion-safe:animate-ping"></span>
        <span class="relative inline-flex size-1.5 bg-(--tone)"></span>
      </span>
      Needs you
    </span>
    """
  end

  @doc "A ring spinning in the text colour; with reduced motion it stands still."
  attr :class, :any, default: "size-3"

  def spinner(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      class={[
        "inline-block shrink-0 rounded-full border-[1.5px] border-current border-r-transparent",
        "motion-safe:animate-spin",
        @class
      ]}
    ></span>
    """
  end

  @doc """
  What an agent does on the task now (`Task.activity`): a spinner while it runs, a softly
  pulsing dot while its job waits for the scheduler, and for how long, counted up in the
  browser.
  """
  attr :activity, Activity, required: true
  attr :id, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def agent_activity(assigns) do
    ~H"""
    <span
      id={@id}
      role="status"
      data-state={@activity.state}
      data-stage={@activity.stage}
      class={[
        "orpheus-badge gap-1.5 font-semibold ring-1 ring-(--tone)/35 ring-inset",
        if(@activity.state == :running, do: "tone-accent", else: "tone-slate"),
        @class
      ]}
      {@rest}
    >
      <%= if @activity.state == :running do %>
        <.spinner class="size-2.5 text-(--tone)" />
      <% else %>
        <span class="size-1.5 shrink-0 bg-(--tone) motion-safe:animate-pulse"></span>
      <% end %>
      {activity_label(@activity)}
      <span
        :if={@activity.since}
        id={"#{@id}-elapsed"}
        phx-hook=".Elapsed"
        phx-update="ignore"
        data-since={DateTime.to_iso8601(@activity.since)}
        class="font-normal normal-case tabular-nums opacity-75"
      ></span>
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Elapsed">
      // Counts up from data-since every second; it is read on each tick, so a new job's
      // start (an attribute LiveView still patches) carries over without a remount.
      const format = (s) =>
        s < 60 ? `${s}s` :
        s < 3600 ? `${Math.floor(s / 60)}m ${s % 60}s` :
        `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`

      export default {
        mounted() {
          this.tick()
          this.timer = setInterval(() => this.tick(), 1000)
        },
        destroyed() {
          clearInterval(this.timer)
        },
        tick() {
          const ms = Date.now() - Date.parse(this.el.dataset.since)
          this.el.textContent = `· ${format(Math.max(0, Math.floor(ms / 1000)))}`
        },
      }
    </script>
    """
  end

  defp activity_label(%Activity{stage: :ask, state: :running}), do: "Answering question"
  defp activity_label(%Activity{stage: :ask, state: :queued}), do: "Question queued"
  defp activity_label(%Activity{stage: stage, state: :running}), do: "#{worker(stage)} working"
  defp activity_label(%Activity{stage: stage, state: :queued}), do: "#{worker(stage)} queued"

  defp worker(:planning), do: "Planner"
  defp worker(:coding), do: "Coder"
  defp worker(:code_review), do: "Reviewer"
  defp worker(:qa), do: "Docker reviewer"
  defp worker(:merging), do: "Merger"
  defp worker(nil), do: "Agent"
end
