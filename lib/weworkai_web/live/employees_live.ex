defmodule WeworkaiWeb.EmployeesLive do
  use WeworkaiWeb, :live_view

  alias Weworkai.{Agents, Connectors, Organization}
  import WeworkaiWeb.UsageComponents, only: [budget_meter: 1]

  alias Weworkai.Agents.Agent.{BudgetPeriod, Role}
  alias Weworkai.Agents.Budget
  alias Weworkai.Connectors.Connector.Status
  alias Weworkai.Organization.Employee.Kind
  alias WeworkaiWeb.Pagination

  @page_size 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Employees")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket = load_page(socket, Pagination.page_number(params["page"]))

    if socket.assigns.page_number > socket.assigns.page_count do
      {:noreply, push_patch(socket, to: list_path(socket.assigns.page_count))}
    else
      {:noreply, apply_action(socket, socket.assigns.live_action, params)}
    end
  end

  defp load_page(socket, number) do
    page = Organization.list_employees!(page: Pagination.page_options(number, @page_size))

    socket
    |> assign(
      budgets: budgets(page.results),
      page_number: number,
      page_count: Pagination.page_count(page.count, @page_size),
      employee_count: page.count
    )
    |> stream(:employees, page.results, reset: true)
  end

  # Agent id → its budget for this period, for the agents that have one.
  defp budgets(employees) do
    now = DateTime.utc_now()

    for %{kind: :agent, agent: %{budget_usd: %Decimal{}} = agent} = employee <- employees,
        into: %{},
        do: {agent.id, Budget.agent(%{agent | employee: employee}, now)}
  end

  defp apply_action(socket, :index, _params), do: assign(socket, form: nil, agent_form: nil)

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(agent_form: nil)
    |> assign_connector_options()
    |> assign(form: to_form(Organization.form_to_create_employee()))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Organization.get_employee(id, load: [agent: :connector_link]) do
      {:ok, employee} ->
        socket
        |> assign(agent_form: nil)
        |> assign_connector_options()
        |> assign(
          form:
            to_form(
              Organization.form_to_update_employee(employee,
                params: agent_params(employee)
              )
            )
        )

      {:error, _} ->
        socket
        |> put_flash(:error, "Employee not found.")
        |> push_patch(to: list_path(socket.assigns.page_number))
    end
  end

  defp apply_action(socket, :agent, %{"id" => id}) do
    case Organization.get_employee(id, load: [agent: [connector_link: :connector]]) do
      {:ok, %{kind: :agent} = employee} ->
        socket
        |> assign(
          form: nil,
          configuring: employee,
          agent_form: to_form(Agents.form_to_configure_agent(employee.agent))
        )
        |> assign_async(:model_options, fn -> fetch_model_options(employee) end)

      _ ->
        socket
        |> put_flash(:error, "Agent not found.")
        |> push_patch(to: list_path(socket.assigns.page_number))
    end
  end

  defp fetch_model_options(%{agent: %{connector_link: %{connector: connector}}}) do
    with {:ok, options} <- Connectors.model_options(connector) do
      {:ok, %{model_options: options}}
    end
  end

  defp fetch_model_options(_employee), do: {:error, "Link a connector to this agent first."}

  @impl true
  def handle_event("validate_agent", %{"form" => params}, socket) do
    {:noreply,
     assign(socket, agent_form: AshPhoenix.Form.validate(socket.assigns.agent_form, params))}
  end

  def handle_event("save_agent", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.agent_form, params: params) do
      {:ok, agent} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{socket.assigns.configuring.name} now uses #{model_summary(agent)}."
         )
         |> push_patch(to: list_path(socket.assigns.page_number))}

      {:error, form} ->
        {:noreply, assign(socket, agent_form: form)}
    end
  end

  def handle_event("validate", %{"form" => params}, socket) do
    {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, employee} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{employee.name} saved.")
         |> push_patch(to: list_path(socket.assigns.page_number))}

      {:error, form} ->
        {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, employee} <- Organization.get_employee(id),
         :ok <- Organization.destroy_employee(employee) do
      {:noreply,
       socket
       |> put_flash(:info, "#{employee.name} removed.")
       |> push_patch(to: list_path(socket.assigns.page_number))}
    else
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not remove the employee.")}
    end
  end

  defp assign_connector_options(socket) do
    options =
      Enum.map(Connectors.connector_options!(), fn connector ->
        {"#{connector.name} (#{Status.label(connector.status)})", connector.id}
      end)

    assign(socket, connector_options: options)
  end

  defp agent_params(%{kind: :agent, agent: agent}) do
    %{
      "agent_role" => to_string(agent.role),
      "connector_id" => agent.connector_link && agent.connector_link.connector_id
    }
  end

  defp agent_params(_employee), do: %{}

  # Kind comes from the params while creating and from the record while editing.
  defp agent_form?(form), do: to_string(Phoenix.HTML.Form.input_value(form, :kind)) == "agent"

  defp list_path(page_number), do: ~p"/employees?#{[page: page_number]}"

  defp model_summary(%{model: model, effort: nil}), do: model
  defp model_summary(%{model: model, effort: effort}), do: "#{model} · #{effort}"

  attr :employee, :map, required: true

  defp connector_state(%{employee: %{kind: :human}} = assigns) do
    ~H"""
    <span class="text-(--orpheus-text-muted)">—</span>
    """
  end

  defp connector_state(
         %{employee: %{agent: %{connector_link: %{connector: connector}}}} = assigns
       ) do
    assigns = assign(assigns, :connector, connector)

    ~H"""
    <span :if={@connector.status == :connected} class="orpheus-badge tone-green">
      {@connector.name}
    </span>
    <.link
      :if={@connector.status != :connected}
      navigate={~p"/connectors?#{[selected: @connector.id]}"}
      class="orpheus-badge tone-red hover:underline"
      title="Open this connector"
    >
      {@connector.name} · {Status.label(@connector.status)}
    </.link>
    """
  end

  defp connector_state(assigns) do
    ~H"""
    <span class="orpheus-badge tone-red">Connector removed</span>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:employees}
      notifications={@notifications}
      unread_count={@unread_count}
    >
      <div class="mb-6 flex items-center justify-between">
        <h1 class="text-2xl font-semibold tracking-tight">Employees</h1>
        <.button
          patch={~p"/employees/new?#{[page: @page_number]}"}
          variant="primary"
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-plus-micro" class="size-4" /> New
        </.button>
      </div>

      <.table id="employees" rows={@streams.employees} row_item={fn {_id, employee} -> employee end}>
        <:col :let={employee} label="Name">
          <span class="flex items-center gap-2"><.avatar employee={employee} />{employee.name}</span>
        </:col>
        <:col :let={employee} label="Role">
          {if employee.kind == :agent, do: Role.label(employee.agent.role), else: employee.role}
        </:col>
        <:col :let={employee} label="Type">
          <span class={[
            "orpheus-badge",
            if(employee.kind == :agent, do: "tone-violet", else: "tone-slate")
          ]}>
            {Kind.label(employee.kind)}
          </span>
        </:col>
        <:col :let={employee} label="Connector"><.connector_state employee={employee} /></:col>
        <:col :let={employee} label="Model">
          <span :if={employee.kind == :agent and employee.agent.model}>
            {model_summary(employee.agent)}
          </span>
          <span
            :if={employee.kind == :agent and !employee.agent.model}
            class="text-(--orpheus-text-muted)"
          >
            Not set
          </span>
        </:col>
        <:col :let={employee} label="Budget">
          <.budget_meter
            :if={@budgets[employee.agent_id]}
            id={"budget-#{employee.id}"}
            budget={@budgets[employee.agent_id]}
          />
        </:col>
        <:action :let={employee}>
          <.link
            :if={employee.kind == :agent}
            patch={~p"/employees/#{employee.id}/agent?#{[page: @page_number]}"}
            aria-label={"Configure #{employee.name}"}
            class="text-primary"
          >
            Configure
          </.link>
        </:action>
        <:action :let={employee}>
          <.link
            patch={~p"/employees/#{employee.id}/edit?#{[page: @page_number]}"}
            aria-label={"Edit #{employee.name}"}
          >
            Edit
          </.link>
        </:action>
        <:action :let={employee}>
          <.link
            phx-click="delete"
            phx-value-id={employee.id}
            data-confirm={"Remove #{employee.name}?"}
            aria-label={"Remove #{employee.name}"}
            class="text-error"
          >
            Remove
          </.link>
        </:action>
      </.table>

      <p :if={@employee_count == 0} class="py-8 text-center text-sm text-(--orpheus-text-muted)">
        No employees yet.
      </p>

      <.pagination page_number={@page_number} page_count={@page_count} path={&list_path/1} />

      <.modal :if={@form} id="employee-modal" on_cancel={JS.patch(list_path(@page_number))}>
        <:title>{if @live_action == :new, do: "New employee", else: "Edit employee"}</:title>
        <.form for={@form} id="employee-form" phx-change="validate" phx-submit="save">
          <.input
            :if={@live_action == :new}
            field={@form[:kind]}
            type="select"
            label="Type"
            options={Enum.map(Kind.values(), &{Kind.label(&1), &1})}
          />
          <.input field={@form[:name]} label="Name" phx-mounted={JS.focus()} />
          <.input
            :if={!agent_form?(@form)}
            field={@form[:role]}
            label="Role"
            placeholder="e.g. Founder"
          />
          <.input
            :if={agent_form?(@form)}
            field={@form[:agent_role]}
            type="select"
            label="Role"
            prompt="Choose a role"
            options={Enum.map(Role.values(), &{Role.label(&1), &1})}
          />
          <.input
            :if={agent_form?(@form)}
            field={@form[:connector_id]}
            type="select"
            label="Connector"
            prompt="Choose a connector"
            options={@connector_options}
          />
          <p :if={agent_form?(@form) and @connector_options == []} class="mb-2 text-xs text-error">
            No connectors yet.
            <.link navigate={~p"/connectors/new"} class="underline">Create one</.link>
            first.
          </p>
          <div class="mt-4 flex justify-end gap-2">
            <.button patch={list_path(@page_number)} class="btn btn-ghost btn-sm">Cancel</.button>
            <.button variant="primary" class="btn btn-primary btn-sm" phx-disable-with="Saving…">
              Save
            </.button>
          </div>
        </.form>
      </.modal>

      <.modal :if={@agent_form} id="agent-modal" on_cancel={JS.patch(list_path(@page_number))}>
        <:title>Configure {@configuring.name}</:title>
        <.async_result :let={options} assign={@model_options}>
          <:loading>
            <p class="text-sm text-(--orpheus-text-muted)">Loading models from the connector…</p>
          </:loading>
          <:failed :let={{:error, message}}>
            <p class="text-sm text-error">{message}</p>
            <div class="mt-4 flex justify-end">
              <.button patch={list_path(@page_number)} class="btn btn-ghost btn-sm">Close</.button>
            </div>
          </:failed>
          <.form
            for={@agent_form}
            id="agent-form"
            phx-change="validate_agent"
            phx-submit="save_agent"
          >
            <.input
              field={@agent_form[:model]}
              type="select"
              label="Model"
              prompt="Choose a model"
              options={Enum.map(options.models, &{&1.label, &1.id})}
            />
            <.input
              field={@agent_form[:effort]}
              type="select"
              label="Effort"
              prompt="Provider default"
              options={options.efforts}
            />
            <.input
              field={@agent_form[:prompt]}
              type="textarea"
              label="Prompt"
              rows="8"
              placeholder="e.g. You can use the GitHub CLI and run the test suite before finishing."
            />
            <div class="grid grid-cols-[1fr_auto] gap-2">
              <.input
                field={@agent_form[:budget_usd]}
                type="number"
                step="0.01"
                min="0.01"
                label="Budget (USD)"
                placeholder="No cap"
              />
              <.input
                field={@agent_form[:budget_period]}
                type="select"
                label="Per"
                options={Enum.map(BudgetPeriod.values(), &{BudgetPeriod.label(&1), &1})}
              />
            </div>
            <p class="-mt-1 mb-2 text-xs text-(--orpheus-text-muted)">
              Warns at 80%; at the cap no new run starts and its task waits for you.
            </p>
            <p
              :if={Role.read_only?(@configuring.agent.role)}
              class="mb-2 flex items-center gap-1.5 text-xs text-(--orpheus-text-muted)"
            >
              <.icon name="hero-eye-micro" class="size-4" />
              {Role.label(@configuring.agent.role)} agents run in a sandboxed container; the repository is mounted read-only.
            </p>
            <p
              :if={@configuring.agent.role == :merger}
              class="mb-2 flex items-center gap-1.5 text-xs text-(--orpheus-text-muted)"
            >
              <.icon name="hero-arrows-pointing-in-micro" class="size-4" />
              Merger agents get the whole repository writable: they merge task branches into its branches.
            </p>
            <div class="mt-4 flex justify-end gap-2">
              <.button patch={list_path(@page_number)} class="btn btn-ghost btn-sm">Cancel</.button>
              <.button variant="primary" class="btn btn-primary btn-sm" phx-disable-with="Saving…">
                Save
              </.button>
            </div>
          </.form>
        </.async_result>
      </.modal>
    </Layouts.app>
    """
  end
end
