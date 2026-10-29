defmodule WeworkaiWeb.TimelineComponents do
  @moduledoc """
  The audit page's Gantt chart (`Weworkai.Audit.Timeline`): a lane per block or agent,
  each job a bar (hatched while queued, solid while its agent ran, shimmering while it
  still runs), the human steps as amber points with a guide down the chart, and the
  stretches the task waited on people hatched amber across all lanes.
  """
  use WeworkaiWeb, :html

  import WeworkaiWeb.UsageComponents, only: [usage: 1, tokens: 1, cost: 1]

  alias Weworkai.Agents.Agent.Role
  alias Weworkai.Agents.Usage
  alias Weworkai.Audit.Timeline

  @stage_tones %{
    planning: "violet",
    coding: "blue",
    code_review: "sky",
    qa: "green",
    merging: "amber",
    ask: "slate"
  }

  attr :totals, :map, required: true
  attr :live?, :boolean, required: true

  def stats(assigns) do
    ~H"""
    <dl id="audit-stats" class="grid grid-cols-2 gap-3 sm:grid-cols-4">
      <.stat
        id="audit-stat-total"
        label={if @live?, do: "So far", else: "Total"}
        value={Timeline.duration(@totals.wall_ms)}
      />
      <.stat
        id="audit-stat-running"
        label="Agents working"
        value={Timeline.duration(@totals.running_ms)}
        tone="tone-blue"
      />
      <.stat
        id="audit-stat-queued"
        label="Queued"
        value={Timeline.duration(@totals.queued_ms)}
        tone="tone-slate"
      />
      <.stat
        id="audit-stat-waiting"
        label="Waiting on people"
        value={Timeline.duration(@totals.waiting_ms)}
        tone="tone-amber"
      />
      <.stat id="audit-stat-runs" label="Agent runs" value={@totals.runs} />
      <.stat id="audit-stat-steps" label="Human steps" value={@totals.human_steps} tone="tone-amber" />
      <.stat id="audit-stat-tokens" label="Tokens" value={tokens(Usage.tokens(@totals.usage))} />
      <.stat id="audit-stat-cost" label="Cost" value={cost(@totals.usage.cost_usd)} />
    </dl>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tone, :string, default: nil

  defp stat(assigns) do
    ~H"""
    <div id={@id} class={["orpheus-card px-4 py-3", @tone]}>
      <dt class="flex items-center gap-1.5 text-xs text-(--orpheus-text-muted)">
        <span :if={@tone} class="size-2 rounded-full bg-(--tone)"></span>{@label}
      </dt>
      <dd class="mt-1 text-lg font-semibold tabular-nums">{@value}</dd>
    </div>
    """
  end

  attr :timeline, Timeline, required: true
  attr :selected, :string, default: nil

  def gantt(assigns) do
    ~H"""
    <div id="gantt" class="audit-gantt orpheus-card overflow-x-auto">
      <div class="min-w-[44rem]">
        <div class="audit-row">
          <div class="audit-label text-[11px] font-medium tracking-wider text-(--orpheus-text-muted) uppercase">
            Elapsed
          </div>
          <div class="audit-track">
            <span :for={tick <- @timeline.ticks} class="audit-tick" style={"left: #{tick.left}%"}>
              {tick.label}
            </span>
          </div>
        </div>
        <div class="relative">
          <div class="audit-overlay" aria-hidden="true">
            <span
              :for={tick <- @timeline.ticks}
              class="audit-gridline"
              style={"left: #{tick.left}%"}
            ></span>
            <span
              :for={wait <- @timeline.waits}
              class="audit-wait"
              style={"left: #{wait.left}%; width: #{wait.width}%"}
            ></span>
            <span
              :for={point <- @timeline.points}
              class="audit-guide"
              style={"left: #{point.left}%"}
            ></span>
            <span :if={@timeline.live?} class="audit-now"></span>
          </div>

          <div :if={@timeline.points != []} id="gantt-lane-people" class="audit-row">
            <div class="audit-label flex items-center gap-2">
              <span class="flex size-6 shrink-0 items-center justify-center rounded-full bg-base-300 text-(--orpheus-text-secondary)">
                <.icon name="hero-user-micro" class="size-3.5" />
              </span>
              <div class="min-w-0">
                <p class="truncate text-sm font-medium">People</p>
                <p class="truncate text-xs text-(--orpheus-text-muted)">
                  {steps(length(@timeline.points))}
                </p>
              </div>
            </div>
            <div class="audit-track">
              <span
                :for={point <- @timeline.points}
                id={"gantt-point-#{point.id}"}
                data-kind={point.kind}
                class="audit-point"
                style={"left: #{point.left}%"}
                title={"#{point.label} · #{clock(point.at)}"}
              ></span>
            </div>
          </div>

          <div :for={lane <- @timeline.lanes} id={"gantt-lane-#{lane.id}"} class="audit-row">
            <div class="audit-label flex items-center gap-2">
              <%= if lane.employee do %>
                <.avatar employee={lane.employee} />
              <% else %>
                <span class={[
                  "flex size-6 shrink-0 items-center justify-center rounded-md bg-(--tone-soft) text-(--tone)",
                  stage_tone(hd(lane.bars).stage)
                ]}>
                  <.icon name="hero-squares-2x2-micro" class="size-3.5" />
                </span>
              <% end %>
              <div class="min-w-0">
                <p class="truncate text-sm font-medium" title={lane.label}>{lane.label}</p>
                <p class="truncate text-xs text-(--orpheus-text-muted)" title={lane.sublabel}>
                  {lane.sublabel} · {Timeline.duration(lane.running_ms)}
                </p>
              </div>
            </div>
            <div class="audit-track">
              <button
                :for={bar <- lane.bars}
                id={"gantt-bar-#{bar.id}"}
                type="button"
                phx-click="select_bar"
                phx-value-id={bar.id}
                aria-pressed={to_string(@selected == bar.id)}
                aria-label={bar_title(bar)}
                title={bar_title(bar)}
                data-status={bar.status}
                data-live={bar.live?}
                class={["audit-bar", bar_tone(bar)]}
                style={"left: #{bar.left}%; width: #{bar.width}%"}
              >
                <span
                  :if={bar.queued_ms > 0}
                  class="audit-bar-queued"
                  style={"flex-grow: #{bar.queued_ms}"}
                ></span>
                <span
                  :if={bar.started_at}
                  class="audit-bar-running"
                  style={"flex-grow: #{max(bar.running_ms, 1)}"}
                ></span>
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def legend(assigns) do
    ~H"""
    <ul
      id="audit-legend"
      class="flex flex-wrap items-center gap-x-5 gap-y-2 text-xs text-(--orpheus-text-muted)"
    >
      <li class="flex items-center gap-1.5 tone-blue">
        <span class="audit-bar-queued h-2.5 w-5 rounded-sm"></span> Queued
      </li>
      <li class="flex items-center gap-1.5 tone-blue">
        <span class="audit-bar-running h-2.5 w-5 rounded-sm"></span> Agent running
      </li>
      <li class="flex items-center gap-1.5">
        <span class="audit-wait-swatch h-2.5 w-5 rounded-sm"></span> Waiting on people
      </li>
      <li class="flex items-center gap-1.5">
        <span class="size-2.5 rotate-45 rounded-[2px] bg-amber-500"></span> Human step
      </li>
      <li class="flex items-center gap-1.5 tone-red">
        <span class="audit-bar-running h-2.5 w-5 rounded-sm"></span> Failed
      </li>
    </ul>
    """
  end

  attr :bar, :map, required: true

  def bar_details(assigns) do
    ~H"""
    <section id="audit-bar-details" class={["orpheus-card p-4", bar_tone(@bar)]}>
      <header class="mb-3 flex flex-wrap items-center gap-3">
        <.avatar employee={@bar.employee} />
        <div class="min-w-0">
          <h3 class="truncate font-medium">{@bar.block}</h3>
          <p class="text-xs text-(--orpheus-text-muted)">
            {@bar.employee.name} · {Role.label(@bar.role)}
          </p>
        </div>
        <span class="orpheus-badge" data-status={@bar.status}>{status_text(@bar.status)}</span>
        <div class="ml-auto flex items-center gap-1">
          <.link
            :if={@bar.run_id}
            id="audit-bar-run"
            navigate={~p"/dashboard/runs/#{@bar.run_id}"}
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-command-line-micro" class="size-4" /> Run log
          </.link>
          <button
            type="button"
            phx-click="select_bar"
            phx-value-id={@bar.id}
            class="btn btn-ghost btn-xs btn-square"
            aria-label="Close"
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </div>
      </header>
      <dl class="grid grid-cols-2 gap-x-6 gap-y-3 text-sm sm:grid-cols-4">
        <div>
          <dt class="text-xs text-(--orpheus-text-muted)">Queued at</dt>
          <dd class="tabular-nums">{clock(@bar.queued_at)}</dd>
        </div>
        <div>
          <dt class="text-xs text-(--orpheus-text-muted)">Waited in queue</dt>
          <dd class="tabular-nums">{Timeline.duration(@bar.queued_ms)}</dd>
        </div>
        <div>
          <dt class="text-xs text-(--orpheus-text-muted)">Ran for</dt>
          <dd class="tabular-nums">
            {if @bar.started_at, do: Timeline.duration(@bar.running_ms), else: "Never started"}
          </dd>
        </div>
        <div>
          <dt class="text-xs text-(--orpheus-text-muted)">Attempts</dt>
          <dd class="tabular-nums">{@bar.attempts}</dd>
        </div>
        <div :if={@bar.usage.runs > 0} id="audit-bar-usage" class="col-span-2">
          <dt class="text-xs text-(--orpheus-text-muted)">Used</dt>
          <dd><.usage usage={@bar.usage} /></dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :rows, :list, required: true

  def breakdown(assigns) do
    ~H"""
    <section id="audit-breakdown" class="orpheus-card p-4">
      <h3 class="text-sm font-medium">Where the time went</h3>
      <p class="mb-4 text-xs text-(--orpheus-text-muted)">
        Agent time per lane, queued then running, beside the time the task waited on people.
      </p>
      <ol class="space-y-2.5">
        <li
          :for={{row, index} <- Enum.with_index(@rows)}
          id={"audit-breakdown-#{row.id}"}
          class="grid grid-cols-[11rem_1fr_5rem] items-center gap-3 text-sm"
        >
          <span class="flex min-w-0 items-center gap-1.5">
            <span class="truncate" title={row.label}>{row.label}</span>
            <span :if={index == 0} class="orpheus-badge tone-amber shrink-0 text-[10px]">
              Longest
            </span>
          </span>
          <span class={["audit-share", row_tone(row)]}>
            <span class="audit-share-fill" style={"width: #{row.width}%"}>
              <span class="audit-share-running" style={"width: #{row.running_share}%"}></span>
            </span>
          </span>
          <span class="text-right tabular-nums text-(--orpheus-text-secondary)">
            {Timeline.duration(row.ms)}
          </span>
        </li>
      </ol>
    </section>
    """
  end

  defp stage_tone(stage), do: "tone-#{Map.get(@stage_tones, stage, "slate")}"

  defp bar_tone(%{status: :failed}), do: "tone-red"
  defp bar_tone(%{stage: stage}), do: stage_tone(stage)

  defp row_tone(%{kind: :waiting}), do: "tone-amber"
  defp row_tone(%{stage: stage}), do: stage_tone(stage)

  defp bar_title(bar) do
    ran = if bar.started_at, do: "ran #{Timeline.duration(bar.running_ms)}", else: "never ran"

    "#{bar.block} · #{bar.employee.name} · #{status_text(bar.status)} · " <>
      "queued #{Timeline.duration(bar.queued_ms)}, #{ran}"
  end

  defp status_text(:done), do: "Done"
  defp status_text(:failed), do: "Failed"
  defp status_text(:canceled), do: "Canceled"
  defp status_text(:on_hold), do: "On hold"
  defp status_text(:in_progress), do: "Running"
  defp status_text(_waiting), do: "Queued"

  defp steps(1), do: "1 step"
  defp steps(count), do: "#{count} steps"

  defp clock(at), do: Calendar.strftime(at, "%b %-d, %H:%M:%S")
end
