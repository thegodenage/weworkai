defmodule WeworkaiWeb.WorkflowsLive do
  @moduledoc """
  The workflows tasks can run (docs/workflows.md): list, create (empty, as a copy of
  another, or from a seeded template), rename, reorder (the first is the default for new
  tasks) and delete one no task uses.
  """
  use WeworkaiWeb, :live_view

  alias Weworkai.{ErrorText, Workflows}
  alias Weworkai.Workflows.Workflow.Template

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Workflows") |> refresh()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: assign(socket, form: nil)

  defp apply_action(socket, :new, _params) do
    assign(socket, form: to_form(Workflows.form_to_create_workflow(params: %{"source_id" => ""})))
  end

  defp apply_action(socket, :template, _params) do
    socket
    |> assign(templates: Workflows.list_templates!())
    |> assign(form: to_form(Workflows.form_to_create_workflow(params: %{"source_id" => ""})))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Workflows.get_workflow(id) do
      {:ok, workflow} ->
        assign(socket, form: to_form(Workflows.form_to_rename_workflow(workflow)))

      {:error, _} ->
        socket |> put_flash(:error, "Workflow not found.") |> push_patch(to: ~p"/workflows")
    end
  end

  defp refresh(socket) do
    workflows = Workflows.list_workflows!()

    socket
    |> assign(workflows: workflows, order: Enum.map(workflows, & &1.id))
    |> stream(:workflows, workflows, reset: true)
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  # A new workflow opens in the editor; a renamed one stays in the list.
  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: source(params)) do
      {:ok, workflow} when socket.assigns.live_action in [:new, :template] ->
        {:noreply, push_navigate(socket, to: ~p"/workflows/#{workflow.id}")}

      {:ok, _workflow} ->
        {:noreply,
         socket |> refresh() |> put_flash(:info, "Saved.") |> push_patch(to: ~p"/workflows")}

      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("move", %{"id" => id, "direction" => direction}, socket) do
    workflow = Workflows.get_workflow!(id)
    :ok = Workflows.move_workflow(workflow, if(direction == "up", do: :up, else: :down))
    {:noreply, refresh(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, workflow} <- Workflows.get_workflow(id),
         :ok <- Workflows.destroy_workflow(workflow) do
      {:noreply, socket |> refresh() |> put_flash(:info, "Workflow deleted.")}
    else
      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Not deleted: #{ErrorText.readable(error)}.")}
    end
  end

  defp source(%{"source_id" => ""} = params), do: Map.put(params, "empty", "true")
  defp source(params), do: params

  defp position(order, workflow), do: Enum.find_index(order, &(&1 == workflow.id))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:workflows}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <div class="mb-2 flex items-center justify-between">
        <h1 class="text-2xl font-semibold tracking-tight">Workflows</h1>
        <div class="flex items-center gap-2">
          <.button
            id="new-from-template"
            patch={~p"/workflows/from-template"}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-squares-plus-micro" class="size-4" /> New from template
          </.button>
          <.button
            id="new-workflow"
            patch={~p"/workflows/new"}
            variant="primary"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus-micro" class="size-4" /> New
          </.button>
        </div>
      </div>
      <p class="mb-6 max-w-2xl text-sm text-(--orpheus-text-muted)">
        The blocks and arrows a task runs through. New tasks run the first one unless you pick another.
      </p>

      <ol id="workflows" phx-update="stream" class="orpheus-card divide-y divide-(--orpheus-border)">
        <li
          :for={{dom_id, workflow} <- @streams.workflows}
          id={dom_id}
          class="group flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3 transition-colors hover:bg-(--orpheus-hover)"
        >
          <div class="flex flex-col">
            <button
              id={"workflow-#{workflow.id}-up"}
              type="button"
              phx-click="move"
              phx-value-id={workflow.id}
              phx-value-direction="up"
              disabled={position(@order, workflow) == 0}
              aria-label={"Move #{workflow.name} up"}
              class="btn btn-ghost btn-xs btn-square disabled:opacity-30"
            >
              <.icon name="hero-chevron-up-micro" class="size-4" />
            </button>
            <button
              id={"workflow-#{workflow.id}-down"}
              type="button"
              phx-click="move"
              phx-value-id={workflow.id}
              phx-value-direction="down"
              disabled={position(@order, workflow) == length(@order) - 1}
              aria-label={"Move #{workflow.name} down"}
              class="btn btn-ghost btn-xs btn-square disabled:opacity-30"
            >
              <.icon name="hero-chevron-down-micro" class="size-4" />
            </button>
          </div>
          <div class="min-w-0 flex-1">
            <.link
              id={"workflow-#{workflow.id}-open"}
              navigate={~p"/workflows/#{workflow.id}"}
              class="font-medium break-words transition-colors hover:text-primary"
            >
              {workflow.name}
            </.link>
            <span
              :if={position(@order, workflow) == 0}
              id={"workflow-#{workflow.id}-default"}
              class="orpheus-badge tone-violet ml-2"
            >
              Default
            </span>
            <span
              :if={workflow.template}
              id={"workflow-#{workflow.id}-template"}
              class="orpheus-badge tone-slate ml-2"
              title="New from template copies it; editing it changes what later copies start with"
            >
              Template
            </span>
            <span
              :if={workflow.problem_count > 0}
              id={"workflow-#{workflow.id}-problems"}
              class="orpheus-badge tone-red ml-2"
              title="Tasks can't run it until its problems are fixed in the editor"
            >
              <.icon name="hero-exclamation-circle-micro" class="size-3.5" />
              {count(workflow.problem_count, "problem")}
            </span>
            <p class="mt-0.5 text-xs text-(--orpheus-text-muted)">
              <span id={"workflow-#{workflow.id}-blocks"}>{count(workflow.block_count, "block")}</span>
              · <span id={"workflow-#{workflow.id}-tasks"}>{count(workflow.task_count, "task")}</span>
              ·
              <span id={"workflow-#{workflow.id}-version"} class="font-mono">v{workflow.version}</span>
            </p>
          </div>
          <div class="flex items-center gap-1 transition-opacity sm:opacity-60 sm:group-hover:opacity-100">
            <.link
              id={"workflow-#{workflow.id}-rename"}
              patch={~p"/workflows/#{workflow.id}/edit"}
              aria-label={"Rename #{workflow.name}"}
              class="btn btn-ghost btn-xs"
            >
              Rename
            </.link>
            <button
              id={"workflow-#{workflow.id}-delete"}
              type="button"
              phx-click="delete"
              phx-value-id={workflow.id}
              data-confirm={"Delete #{workflow.name}?"}
              aria-label={"Delete #{workflow.name}"}
              class="btn btn-ghost btn-xs text-error hover:bg-error/10"
            >
              Delete
            </button>
          </div>
        </li>
      </ol>

      <.modal :if={@form} id="workflow-modal" on_cancel={JS.patch(~p"/workflows")}>
        <:title>{modal_title(@live_action)}</:title>
        <.form for={@form} id="workflow-form" phx-change="validate" phx-submit="save">
          <.input
            field={@form[:name]}
            label="Name"
            placeholder="e.g. Quick fixes"
            phx-mounted={JS.focus()}
          />
          <.input
            :if={@live_action == :new}
            field={@form[:source_id]}
            type="select"
            label="Start from"
            options={[
              {"An empty canvas", ""} | Enum.map(@workflows, &{"A copy of #{&1.name}", &1.id})
            ]}
          />
          <p :if={@live_action == :new} class="mb-2 text-xs text-(--orpheus-text-muted)">
            A copy gets its own blocks and arrows; changing one workflow never changes the other.
          </p>
          <.template_choice :if={@live_action == :template} form={@form} templates={@templates} />
          <div class="mt-4 flex justify-end gap-2">
            <.button patch={~p"/workflows"} class="btn btn-ghost btn-sm">Cancel</.button>
            <.button variant="primary" class="btn btn-primary btn-sm" phx-disable-with="Saving…">
              Save
            </.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  attr :form, :map, required: true
  attr :templates, :list, required: true

  # Blank, then each seeded template still there, as radio cards.
  defp template_choice(assigns) do
    ~H"""
    <fieldset id="template-choice" class="mb-2">
      <legend class="mb-2 text-sm font-medium">Start from</legend>
      <div class="grid gap-2">
        <.template_option
          form={@form}
          value=""
          id="template-blank"
          title="Blank"
          description="An empty canvas: draw your own blocks and arrows."
        />
        <.template_option
          :for={template <- @templates}
          form={@form}
          value={template.id}
          id={"template-#{template.template}"}
          title={template.name}
          description={Template.description(template.template)}
          blocks={template.block_count}
        />
      </div>
      <p class="mt-2 text-xs text-(--orpheus-text-muted)">
        You get a copy to change as you like; the template stays as it is.
      </p>
    </fieldset>
    """
  end

  attr :form, :map, required: true
  attr :value, :string, required: true
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :blocks, :integer, default: nil

  defp template_option(assigns) do
    ~H"""
    <label
      id={@id}
      class={[
        "flex cursor-pointer items-start gap-3 rounded-lg border px-3 py-2.5 transition-colors",
        "border-(--orpheus-border) hover:bg-(--orpheus-hover)",
        "has-[:checked]:border-primary has-[:checked]:bg-primary/5"
      ]}
    >
      <input
        type="radio"
        id={"#{@id}-input"}
        name={@form[:source_id].name}
        value={@value}
        checked={to_string(@form[:source_id].value || "") == @value}
        class="radio radio-primary radio-sm mt-0.5"
      />
      <span class="min-w-0">
        <span class="block text-sm font-medium">
          {@title}
          <span :if={@blocks} class="font-normal text-(--orpheus-text-muted)">
            · {count(@blocks, "block")}
          </span>
        </span>
        <span class="block text-xs text-(--orpheus-text-muted)">{@description}</span>
      </span>
    </label>
    """
  end

  defp modal_title(:new), do: "New workflow"
  defp modal_title(:template), do: "New from template"
  defp modal_title(:edit), do: "Rename workflow"

  defp count(1, noun), do: "1 #{noun}"
  defp count(number, noun), do: "#{number} #{noun}s"
end
