defmodule WeworkaiWeb.ProofOfWorkComponents do
  @moduledoc """
  The evidence a human weighs at the review gate (`Weworkai.Board.ProofOfWork`): the
  branch's diff stats, open findings, the agents' reports, runs per stage and spend.
  """
  use WeworkaiWeb, :html

  import WeworkaiWeb.UsageComponents, only: [budget_meter: 1, cost: 1, tokens: 1]

  alias Weworkai.Agents.Agent.Role
  alias Weworkai.Agents.Usage
  alias Weworkai.Audit.Timeline
  alias Weworkai.Scheduling.Job.Stage
  alias Weworkai.Scheduling.ScheduledJob.State

  attr :proof, Weworkai.Board.ProofOfWork, required: true
  attr :diff_files, Phoenix.LiveView.AsyncResult, required: true
  attr :task_id, :string, required: true

  def proof_of_work(assigns) do
    ~H"""
    <section id="proof-of-work" class="orpheus-card mb-6" aria-labelledby="proof-of-work-title">
      <header class="flex items-center gap-3 border-b border-(--orpheus-border) px-4 py-2">
        <h2 id="proof-of-work-title" class="micro-label text-base-content">Proof of work</h2>
        <span class="pow-rule" aria-hidden="true"></span>
        <.link
          id="proof-of-work-timeline"
          navigate={~p"/audit/#{@task_id}"}
          class="micro-label transition-colors hover:text-primary"
        >
          Timeline &rarr;
        </.link>
      </header>

      <dl class="pow-stats">
        <.async_result :let={files} assign={@diff_files}>
          <:loading>
            <div id="pow-changes-loading" class="pow-stat col-span-2">
              <dt class="micro-label">Changes</dt>
              <dd class="pow-figure animate-pulse text-(--orpheus-text-muted)">reading branch…</dd>
            </div>
          </:loading>
          <:failed :let={failure}>
            <div id="pow-changes-failed" class="pow-stat col-span-2">
              <dt class="micro-label">Changes</dt>
              <dd class="text-xs text-(--orpheus-text-muted)">{failure_text(failure)}</dd>
            </div>
          </:failed>
          <div id="pow-files" class="pow-stat">
            <dt class="micro-label">Files</dt>
            <dd class="pow-figure">{length(files)}</dd>
          </div>
          <div id="pow-lines" class="pow-stat">
            <dt class="micro-label">Lines</dt>
            <dd class="pow-figure">
              <span class="diff-stat-addition">+{sum(files, :additions)}</span>
              <span class="diff-stat-deletion">−{sum(files, :deletions)}</span>
            </dd>
          </div>
        </.async_result>
        <div id="pow-findings" class="pow-stat">
          <dt class="micro-label">Open findings</dt>
          <dd class="pow-figure flex items-baseline gap-3">
            <%= if Enum.all?(@proof.findings, &(elem(&1, 1) == 0)) do %>
              <span class="orpheus-badge tone-green">Clean</span>
            <% else %>
              <span
                :for={{severity, count} <- @proof.findings}
                id={"pow-findings-#{severity}"}
                class={["tone-#{severity_tone(severity)}", count == 0 && "opacity-40"]}
                title={"#{count} #{severity}"}
              >
                <span class="text-(--tone)">{count}</span><span class="pow-unit">{severity_short(
                  severity
                )}</span>
              </span>
            <% end %>
          </dd>
        </div>
        <div id="pow-spend" class="pow-stat">
          <dt class="micro-label">Spend</dt>
          <dd class="pow-figure">
            {cost(@proof.usage.cost_usd)}<span class="pow-unit">{tokens(Usage.tokens(@proof.usage))} tok</span>
          </dd>
          <dd class="mt-1">
            <%= if @proof.budget do %>
              <.budget_meter id="pow-budget" budget={@proof.budget} />
            <% else %>
              <span id="pow-budget" class="text-xs text-(--orpheus-text-muted)">no cap</span>
            <% end %>
          </dd>
        </div>
      </dl>

      <div class="grid lg:grid-cols-2">
        <div class="pow-pane">
          <h3 class="micro-label mb-2">Changed files</h3>
          <.async_result :let={files} assign={@diff_files}>
            <:loading>
              <p class="text-xs text-(--orpheus-text-muted)">…</p>
            </:loading>
            <:failed>
              <p class="text-xs text-(--orpheus-text-muted)">—</p>
            </:failed>
            <p :if={files == []} class="text-xs text-(--orpheus-text-muted)">
              The branch changes nothing.
            </p>
            <ol id="pow-file-list" class="pow-files">
              <li :for={{{path, diff}, index} <- Enum.with_index(files)} id={"pow-file-#{index}"}>
                <code class="truncate" title={path}>{path}</code>
                <span class="diff-stat-addition">+{diff.additions}</span>
                <span class="diff-stat-deletion">−{diff.deletions}</span>
                <span class="pow-bar" aria-hidden="true">
                  <span
                    class="pow-bar-add"
                    style={"width: #{share(diff.additions, files)}%"}
                  ></span><span
                    class="pow-bar-del"
                    style={"width: #{share(diff.deletions, files)}%"}
                  ></span>
                </span>
              </li>
            </ol>
          </.async_result>
        </div>

        <div class="pow-pane">
          <h3 class="micro-label mb-2">Agent reports</h3>
          <p :if={@proof.reports == []} class="text-xs text-(--orpheus-text-muted)">
            No agent reported yet.
          </p>
          <ol id="pow-reports" class="space-y-2">
            <li :for={report <- @proof.reports} id={"pow-report-#{report.role}"} class="text-sm">
              <div class="flex items-center gap-2">
                <span class="font-medium">{Role.label(report.role)}</span>
                <.verdict open={report.open} />
                <time class="pow-time ml-auto" datetime={DateTime.to_iso8601(report.at)}>
                  {iso(report.at)}
                </time>
              </div>
              <p class="line-clamp-2 text-xs text-(--orpheus-text-secondary)">{report.body}</p>
            </li>
          </ol>
        </div>
      </div>

      <div class="overflow-x-auto border-t border-(--orpheus-border)">
        <table id="pow-stages" class="orpheus-table pow-table">
          <thead>
            <tr>
              <th>Stage</th>
              <th class="text-right">Runs</th>
              <th class="text-right">Failed</th>
              <th class="text-right">Time</th>
              <th class="text-right">Cost</th>
              <th>Last</th>
              <th><span class="sr-only">Log</span></th>
            </tr>
          </thead>
          <tbody class="font-mono">
            <tr :for={stage <- @proof.stages} id={"pow-stage-#{stage.stage || "custom"}"}>
              <td class="font-sans">{stage_label(stage.stage)}</td>
              <td class="text-right">{stage.runs}</td>
              <td class={["text-right", stage.failed > 0 && "text-error"]}>{stage.failed}</td>
              <td class="text-right">{Timeline.duration(stage.duration_ms)}</td>
              <td class="text-right">{cost(stage.cost_usd)}</td>
              <td>
                <span class={["orpheus-badge", "tone-#{state_tone(stage.state)}"]}>
                  {State.label(stage.state)}
                </span>
              </td>
              <td class="text-right">
                <.link
                  navigate={~p"/dashboard/runs/#{stage.last_run_id}"}
                  class="micro-label transition-colors hover:text-primary"
                >
                  log&nbsp;&rarr;
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <footer
        :if={@proof.span}
        id="pow-span"
        class="pow-time flex flex-wrap gap-x-4 border-t border-(--orpheus-border) px-4 py-2"
      >
        <span>first run {iso(elem(@proof.span, 0))}</span>
        <span>last {iso(elem(@proof.span, 1))}</span>
        <span>wall {Timeline.duration(span_ms(@proof.span))}</span>
        <span>{@proof.usage.turns} turns</span>
      </footer>
    </section>
    """
  end

  attr :open, :any, required: true

  defp verdict(%{open: nil} = assigns),
    do: ~H|<span class="orpheus-badge tone-slate">Reported</span>|

  defp verdict(%{open: 0} = assigns), do: ~H|<span class="orpheus-badge tone-green">Clean</span>|
  defp verdict(assigns), do: ~H|<span class="orpheus-badge tone-amber">{@open} open</span>|

  defp failure_text({:error, message}) when is_binary(message), do: message
  defp failure_text(_crash), do: "The branch's diff could not be read."

  defp sum(files, key), do: files |> Enum.map(&Map.fetch!(elem(&1, 1), key)) |> Enum.sum()

  # Bars share one scale: the largest file's change fills its track.
  defp share(count, files) do
    widest =
      files |> Enum.map(fn {_path, diff} -> diff.additions + diff.deletions end) |> Enum.max()

    if widest == 0, do: 0, else: Float.round(count * 100 / widest, 1)
  end

  defp severity_tone(:high), do: "red"
  defp severity_tone(:medium), do: "amber"
  defp severity_tone(:low), do: "slate"

  defp severity_short(:high), do: "high"
  defp severity_short(:medium), do: "med"
  defp severity_short(:low), do: "low"

  defp stage_label(nil), do: "Custom"
  defp stage_label(stage), do: Stage.label(stage)

  defp state_tone(:completed), do: "green"
  defp state_tone(:failed), do: "red"
  defp state_tone(:started), do: "accent"
  defp state_tone(_pending_or_canceled), do: "slate"

  defp iso(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%MZ")

  defp span_ms({first, last}), do: DateTime.diff(last, first, :millisecond)
end
