defmodule WeworkaiWeb.TaskBudget do
  @moduledoc """
  The task's budget in its header: spend against the cap as a meter, or a prompt to set
  one, edited in place. A saved cap reaches the page through the task's update broadcast.
  An empty cap leaves the task uncapped.
  """
  use WeworkaiWeb, :live_component

  import WeworkaiWeb.UsageComponents, only: [budget_meter: 1]

  alias Weworkai.Agents.Budget

  @impl true
  def mount(socket), do: {:ok, assign(socket, form: nil)}

  @impl true
  def update(assigns, socket) do
    budget =
      assigns.task.budget_usd &&
        %Budget{owner: :task, cap: assigns.task.budget_usd, spent: assigns.spent}

    {:ok, socket |> assign(assigns) |> assign(budget: budget)}
  end

  @impl true
  def handle_event("edit", _params, socket) do
    form = AshPhoenix.Form.for_update(socket.assigns.task, :set_budget, as: "budget")
    {:noreply, assign(socket, form: to_form(form))}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, form: nil)}

  def handle_event("validate", %{"budget" => params}, socket) do
    {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"budget" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, _task} -> {:noreply, assign(socket, form: nil)}
      {:error, form} -> {:noreply, assign(socket, form: form)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex items-center gap-1.5">
      <dt><.icon name="hero-banknotes-micro" class="size-4 text-(--orpheus-text-muted)" /></dt>
      <dd>
        <%= cond do %>
          <% @form -> %>
            <.form
              for={@form}
              id={"#{@id}-form"}
              phx-change="validate"
              phx-submit="save"
              phx-target={@myself}
              class="flex items-start gap-1.5"
            >
              <.input
                field={@form[:budget_usd]}
                id={"#{@id}-input"}
                type="number"
                step="0.01"
                min="0.01"
                placeholder="USD, empty: no cap"
                aria-label="Task budget in USD"
                phx-mounted={JS.focus()}
                class="input input-sm w-44 font-mono"
              />
              <button id={"#{@id}-save"} class="btn btn-primary btn-sm">Save</button>
              <button
                type="button"
                id={"#{@id}-cancel"}
                phx-click="cancel"
                phx-target={@myself}
                class="btn btn-ghost btn-sm"
              >
                Cancel
              </button>
            </.form>
          <% @budget -> %>
            <button
              type="button"
              id={"#{@id}-edit"}
              phx-click="edit"
              phx-target={@myself}
              title="Change the budget"
              class="-mx-1 px-1 transition-colors hover:bg-(--orpheus-hover)"
            >
              <.budget_meter id={"#{@id}-meter"} budget={@budget} />
            </button>
          <% true -> %>
            <button
              type="button"
              id={"#{@id}-edit"}
              phx-click="edit"
              phx-target={@myself}
              class="micro-label -mx-1 px-1 transition-colors hover:bg-(--orpheus-hover) hover:text-base-content"
            >
              [+ budget]
            </button>
        <% end %>
      </dd>
    </div>
    """
  end
end
