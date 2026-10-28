defmodule WeworkaiWeb.RecurringLive do
  @moduledoc """
  Crons (docs/recurring.md): workflows run on their own. Each cron names a workflow, when
  it runs (weekdays and a time, or a cron expression) in a time zone, and the task it
  creates then (tagged CRON; runs close together stack on the board). A cron can be run at
  once, paused, edited and deleted; its tasks stay.
  """
  use WeworkaiWeb, :live_view

  alias Phoenix.HTML.Form
  alias Weworkai.{Recurring, Workflows}
  alias Weworkai.Board.Task
  alias Weworkai.Recurring.Runner
  alias WeworkaiWeb.FolderPicker

  @days [{1, "Mon"}, {2, "Tue"}, {3, "Wed"}, {4, "Thu"}, {5, "Fri"}, {6, "Sat"}, {7, "Sun"}]
  @modes [weekly: "Days & time", expression: "Cron expression"]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Recurring",
       workflows: Workflows.list_workflows!(),
       timezone: browser_timezone(socket)
     )
     |> refresh()}
  end

  # Sent by app.js; a zone the database doesn't know (or a dead render) falls back to UTC.
  defp browser_timezone(socket) do
    timezone = get_connect_params(socket)["timezone"]

    if is_binary(timezone) and match?({:ok, _}, DateTime.now(timezone)),
      do: timezone,
      else: "Etc/UTC"
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: assign(socket, form: nil)

  defp apply_action(socket, :new, _params) do
    form =
      Recurring.form_to_create_cron(
        params: %{
          "workflow_id" => Workflows.default_workflow!().id,
          "mode" => "weekly",
          "days" => ["1", "2", "3", "4", "5"],
          "at" => "09:00",
          "timezone" => socket.assigns.timezone,
          "repository" => Task.default_repository(),
          "enabled" => "true"
        }
      )

    assign(socket, form: to_form(form))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Recurring.get_cron(id) do
      {:ok, cron} ->
        assign(socket, form: to_form(Recurring.form_to_update_cron(cron)))

      {:error, _} ->
        socket |> put_flash(:error, "Cron not found.") |> push_patch(to: ~p"/recurring")
    end
  end

  defp refresh(socket), do: stream(socket, :crons, Recurring.list_crons!(), reset: true)

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, days(params)))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: days(params)) do
      {:ok, _cron} ->
        {:noreply,
         socket |> refresh() |> put_flash(:info, "Cron saved.") |> push_patch(to: ~p"/recurring")}

      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    cron = Recurring.get_cron!(id)
    Recurring.update_cron!(cron, %{enabled: not cron.enabled})
    {:noreply, refresh(socket)}
  end

  def handle_event("run", %{"id" => id}, socket) do
    case id |> Recurring.get_cron!() |> Runner.start() do
      {:ok, task} ->
        {:noreply, socket |> refresh() |> put_flash(:info, "Started “#{task.title}”.")}

      {:error, reason} ->
        {:noreply, socket |> refresh() |> put_flash(:error, "Didn't start: #{reason}")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    id |> Recurring.get_cron!() |> Recurring.destroy_cron!()
    {:noreply, socket |> refresh() |> put_flash(:info, "Cron deleted. Its tasks stay.")}
  end

  # Unchecking every day still sends the hidden empty one, so the change reaches the form.
  # In expression mode the chips aren't there: the days stay as they were.
  defp days(%{"days" => days} = params), do: %{params | "days" => Enum.reject(days, &(&1 == ""))}
  defp days(params), do: params

  defp expression_mode?(form), do: to_string(Form.input_value(form, :mode)) == "expression"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:recurring}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <div class="mb-2 flex items-center justify-between">
        <h1 class="text-2xl font-semibold tracking-tight">Recurring</h1>
        <.button
          id="new-cron"
          patch={~p"/recurring/new"}
          variant="primary"
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-plus-micro" class="size-4" /> New cron
        </.button>
      </div>
      <p class="mb-6 max-w-2xl text-sm text-(--orpheus-text-muted)">
        Workflows that run on their own. At each scheduled time a cron creates a task tagged
        <span class="orpheus-badge tone-sky">CRON</span>
        on its workflow and moves it to Todo, which starts it. Runs close together stack into one
        card on the board. A run more than {Runner.grace_minutes()} minutes late (the app wasn't
        running) is skipped.
      </p>

      <ol id="crons" phx-update="stream" class="orpheus-card divide-y divide-(--orpheus-border)">
        <li
          id="crons-empty"
          class="hidden px-4 py-10 text-center text-sm text-(--orpheus-text-muted) only:block"
        >
          <.icon name="hero-arrow-path" class="mx-auto mb-2 size-6 opacity-50" />
          No crons yet. Add one to run a workflow every weekday at 9, or every half hour.
        </li>
        <li
          :for={{dom_id, cron} <- @streams.crons}
          id={dom_id}
          class={[
            "group flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3 transition-colors hover:bg-(--orpheus-hover)",
            !cron.enabled && "opacity-60"
          ]}
        >
          <div class="min-w-0 flex-1">
            <p class="flex flex-wrap items-center gap-2">
              <span class="font-medium break-words">{cron.name}</span>
              <.link
                id={"cron-#{cron.id}-workflow"}
                navigate={~p"/workflows/#{cron.workflow_id}"}
                class="orpheus-badge tone-violet transition-opacity hover:opacity-80"
              >
                {cron.workflow.name}
              </.link>
              <span
                :if={!cron.enabled}
                id={"cron-#{cron.id}-paused"}
                class="orpheus-badge tone-slate"
              >
                Paused
              </span>
            </p>
            <p class="mt-0.5 text-xs text-(--orpheus-text-muted)">
              <span id={"cron-#{cron.id}-when"} class="font-mono">{summary(cron)}</span>
              <span :if={cron.enabled}>
                · next
                <span id={"cron-#{cron.id}-next"}>
                  {Recurring.local_time(cron.next_run_at, cron.timezone)}
                </span>
              </span>
              · <span id={"cron-#{cron.id}-tasks"}>{count(cron.task_count, "task")}</span>
            </p>
            <p :if={cron.last_task_id} class="mt-0.5 text-xs text-(--orpheus-text-muted)">
              Last ran {Recurring.local_time(cron.last_run_at, cron.timezone)}
              <.link
                id={"cron-#{cron.id}-last-task"}
                navigate={~p"/tasks/#{cron.last_task_id}"}
                class="transition-colors hover:text-primary"
              >
                → {cron.last_task_title}
              </.link>
            </p>
            <p
              :if={missed?(cron)}
              id={"cron-#{cron.id}-skipped"}
              class="mt-1 flex items-start gap-1 text-xs text-warning"
            >
              <.icon name="hero-clock-micro" class="mt-px size-3.5 shrink-0" />
              Missed {Recurring.local_time(cron.last_skipped_at, cron.timezone)}: the app wasn't running.
            </p>
            <p
              :if={cron.last_error}
              id={"cron-#{cron.id}-error"}
              class="mt-1 flex items-start gap-1 text-xs text-error"
            >
              <.icon name="hero-exclamation-circle-micro" class="mt-px size-3.5 shrink-0" />
              {cron.last_error}
            </p>
          </div>
          <div class="flex items-center gap-1 transition-opacity sm:opacity-60 sm:group-hover:opacity-100">
            <button
              id={"cron-#{cron.id}-run"}
              type="button"
              phx-click="run"
              phx-value-id={cron.id}
              phx-disable-with="Starting…"
              class="btn btn-ghost btn-xs"
            >
              <.icon name="hero-play-micro" class="size-3.5" /> Run now
            </button>
            <button
              id={"cron-#{cron.id}-toggle"}
              type="button"
              phx-click="toggle"
              phx-value-id={cron.id}
              class="btn btn-ghost btn-xs"
            >
              {if(cron.enabled, do: "Pause", else: "Resume")}
            </button>
            <.link
              id={"cron-#{cron.id}-edit"}
              patch={~p"/recurring/#{cron.id}/edit"}
              class="btn btn-ghost btn-xs"
            >
              Edit
            </.link>
            <button
              id={"cron-#{cron.id}-delete"}
              type="button"
              phx-click="delete"
              phx-value-id={cron.id}
              data-confirm={"Delete #{cron.name}? The tasks it created stay."}
              class="btn btn-ghost btn-xs text-error hover:bg-error/10"
            >
              Delete
            </button>
          </div>
        </li>
      </ol>

      <.modal :if={@form} id="cron-modal" on_cancel={JS.patch(~p"/recurring")}>
        <:title>{if(@live_action == :new, do: "New cron", else: "Edit cron")}</:title>
        <.form for={@form} id="cron-form" phx-change="validate" phx-submit="save">
          <.input
            field={@form[:name]}
            label="Name"
            placeholder="e.g. Daily GitLab digest"
            phx-mounted={JS.focus()}
          />
          <p class="-mt-1 mb-2 text-xs text-(--orpheus-text-muted)">
            Each run's task is named after it, with the day: “Daily GitLab digest · Wed 28 Oct”.
          </p>
          <.input
            field={@form[:workflow_id]}
            type="select"
            label="Workflow"
            options={workflow_options(@workflows)}
            class="select w-full"
          />
          <.mode_toggle field={@form[:mode]} />
          <%= if expression_mode?(@form) do %>
            <.input
              field={@form[:expression]}
              id="cron-expression"
              label="Cron expression"
              placeholder="0 9 * * 1-5"
              autocomplete="off"
              class="input w-full font-mono"
            />
            <p class="-mt-1 mb-1 text-xs text-(--orpheus-text-muted)">
              minute · hour · day of month · month · weekday, on the time zone's clock:
              <code class="font-mono">0 9 * * 1-5</code>
              weekdays at 9:00, <code class="font-mono">*/30 8-18 * * *</code>
              every half hour from 8:00 to 18:30. Runs at most {Runner.group_gap_minutes()} minutes
              apart stack into one card a day.
            </p>
            <.upcoming form={@form} />
          <% else %>
            <.days_picker field={@form[:days]} />
          <% end %>
          <div class={["grid gap-3", !expression_mode?(@form) && "grid-cols-2"]}>
            <.input :if={!expression_mode?(@form)} field={@form[:at]} type="time" label="Time" />
            <.input field={@form[:timezone]} label="Time zone" placeholder="Europe/Warsaw" />
          </div>
          <.input
            field={@form[:description]}
            type="textarea"
            label="What to do"
            rows="5"
            placeholder="Fetch the newest GitLab merge request comments and summarise them…"
          />
          <.live_component
            module={FolderPicker}
            id="cron-form-repository"
            field={@form[:repository]}
            label="Repository"
          />
          <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
          <div class="mt-4 flex justify-end gap-2">
            <.button patch={~p"/recurring"} class="btn btn-ghost btn-sm">Cancel</.button>
            <.button variant="primary" class="btn btn-primary btn-sm" phx-disable-with="Saving…">
              Save
            </.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  # Two segments: the picker, or an expression for the advanced cases.
  defp mode_toggle(assigns) do
    assigns = assign(assigns, modes: @modes, current: to_string(assigns.field.value || :weekly))

    ~H"""
    <fieldset id="cron-mode" class="fieldset mb-2">
      <legend class="label mb-1">Repeat</legend>
      <div class="inline-flex rounded-md border border-(--orpheus-border) p-0.5">
        <label
          :for={{mode, label} <- @modes}
          id={"cron-mode-#{mode}"}
          class={[
            "cursor-pointer rounded px-3 py-1 text-sm font-medium transition-colors select-none",
            "text-(--orpheus-text-muted) hover:text-base-content",
            "has-[:checked]:bg-primary/10 has-[:checked]:text-primary"
          ]}
        >
          <input
            type="radio"
            name={@field.name}
            value={mode}
            checked={@current == to_string(mode)}
            class="sr-only"
          />
          {label}
        </label>
      </div>
    </fieldset>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  # The expression's next runs as typed, so its meaning is plain before it is saved.
  defp upcoming(assigns) do
    timezone = Form.input_value(assigns.form, :timezone)

    assigns =
      assign(assigns,
        timezone: timezone,
        preview: Runner.preview(Form.input_value(assigns.form, :expression), timezone)
      )

    ~H"""
    <p
      :if={match?({:ok, [_ | _]}, @preview)}
      id="cron-upcoming"
      class="mb-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-(--orpheus-text-muted)"
    >
      <.icon name="hero-clock-micro" class="size-3.5" /> Next:
      <span :for={run <- elem(@preview, 1)} class="orpheus-badge tone-slate font-mono">
        {Recurring.local_time(run, @timezone)}
      </span>
    </p>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  # One chip per weekday; the hidden empty value lets unchecking every day reach the form.
  defp days_picker(assigns) do
    assigns =
      assign(assigns,
        days: @days,
        checked: Enum.map(List.wrap(assigns.field.value), &to_string/1),
        errors:
          if(used_input?(assigns.field),
            do: Enum.map(assigns.field.errors, &translate_error/1),
            else: []
          )
      )

    ~H"""
    <fieldset id="cron-days" class="fieldset mb-2">
      <legend class="label mb-1">Days</legend>
      <input type="hidden" name={@field.name <> "[]"} value="" />
      <div class="flex flex-wrap gap-1.5">
        <label
          :for={{day, name} <- @days}
          id={"cron-day-#{day}"}
          class={[
            "cursor-pointer rounded-md border px-2.5 py-1 text-sm font-medium transition-colors select-none",
            "border-(--orpheus-border) text-(--orpheus-text-muted) hover:bg-(--orpheus-hover) hover:text-base-content",
            "has-[:checked]:border-primary has-[:checked]:bg-primary/10 has-[:checked]:text-primary"
          ]}
        >
          <input
            type="checkbox"
            name={@field.name <> "[]"}
            value={day}
            checked={to_string(day) in @checked}
            class="sr-only"
          />
          {name}
        </label>
      </div>
      <div :if={@errors != []} id="cron-days-errors" class="mt-1 text-xs text-error">
        <p :for={error <- @errors}>{error}</p>
      </div>
    </fieldset>
    """
  end

  defp workflow_options(workflows) do
    Enum.map(workflows, fn workflow ->
      {if(workflow.problem_count > 0, do: "#{workflow.name} (has problems)", else: workflow.name),
       workflow.id}
    end)
  end

  defp summary(%{mode: :expression} = cron), do: "#{cron.expression} (#{cron.timezone})"

  defp summary(cron),
    do: "#{days_label(cron.days)} at #{Calendar.strftime(cron.at, "%H:%M")} (#{cron.timezone})"

  defp days_label(days) do
    case Enum.sort(days) do
      [1, 2, 3, 4, 5, 6, 7] -> "Every day"
      [1, 2, 3, 4, 5] -> "Weekdays"
      [6, 7] -> "Weekends"
      days -> Enum.map_join(days, ", ", &(@days |> List.keyfind(&1, 0) |> elem(1)))
    end
  end

  # A slot skipped since it last ran.
  defp missed?(%{last_skipped_at: nil}), do: false
  defp missed?(%{last_run_at: nil}), do: true
  defp missed?(cron), do: DateTime.compare(cron.last_skipped_at, cron.last_run_at) == :gt

  defp count(1, noun), do: "1 #{noun}"
  defp count(number, noun), do: "#{number} #{noun}s"
end
