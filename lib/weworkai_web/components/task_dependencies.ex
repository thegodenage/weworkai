defmodule WeworkaiWeb.TaskDependencies do
  @moduledoc """
  The task's place among other tasks, on its page: the tasks it waits on (added and removed
  here), the tasks waiting on it, its parent and its sub-tasks with their progress.
  While a blocker is open the scheduler starts none of the task's agents
  (`Weworkai.Board.TaskDependency`). The page re-renders this with `task` whenever a
  related task changes.
  """
  use WeworkaiWeb, :live_component

  import WeworkaiWeb.TaskComponents, only: [status_badge: 1, subtask_progress: 1]

  alias Weworkai.{Board, ErrorText}

  @impl true
  def mount(socket), do: {:ok, assign(socket, error: nil, subtask_form: subtask_form())}

  @impl true
  def update(assigns, socket), do: {:ok, socket |> assign(assigns) |> load()}

  defp load(socket) do
    task =
      Ash.load!(socket.assigns.task, [:parent, :blockers, :dependents, :children],
        reuse_values?: false
      )

    taken = MapSet.new([task.id | Enum.map(task.blockers, & &1.id)])

    assign(socket,
      parent: task.parent,
      blockers: Enum.sort_by(task.blockers, & &1.title),
      dependents: Enum.sort_by(task.dependents, & &1.title),
      children: Enum.sort_by(task.children, & &1.inserted_at, DateTime),
      choices:
        for(choice <- Board.list_task_choices!(), not MapSet.member?(taken, choice.id)) do
          {"##{short_id(choice)} #{choice.title}", choice.id}
        end,
      blocker_form: to_form(%{"blocker_id" => ""}, as: :blocker)
    )
  end

  defp subtask_form, do: to_form(%{"title" => ""}, as: :subtask)

  @impl true
  def handle_event("add_blocker", %{"blocker" => %{"blocker_id" => ""}}, socket),
    do: {:noreply, socket}

  def handle_event("add_blocker", %{"blocker" => %{"blocker_id" => blocker_id}}, socket) do
    socket.assigns.task.id
    |> Board.add_blocker(blocker_id)
    |> settle(socket)
  end

  def handle_event("remove_blocker", %{"id" => blocker_id}, socket) do
    socket.assigns.task.id
    |> Board.get_dependency!(blocker_id)
    |> Board.remove_blocker()
    |> settle(socket)
  end

  def handle_event("add_subtask", %{"subtask" => %{"title" => title}}, socket) do
    case Board.create_subtask(socket.assigns.task.id, title) do
      {:ok, _child} -> {:noreply, socket |> assign(subtask_form: subtask_form()) |> settle_ok()}
      {:error, error} -> {:noreply, assign(socket, error: ErrorText.readable(error))}
    end
  end

  defp settle(:ok, socket), do: {:noreply, settle_ok(socket)}
  defp settle({:ok, _record}, socket), do: {:noreply, settle_ok(socket)}

  defp settle({:error, error}, socket),
    do: {:noreply, assign(socket, error: ErrorText.readable(error))}

  defp settle_ok(socket), do: socket |> assign(error: nil) |> load()

  defp short_id(task), do: String.slice(task.id, 0, 8)

  defp done_count(children), do: Enum.count(children, &(&1.status == :done))
  defp open_children(children), do: Enum.reject(children, &(&1.status == :canceled))

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="orpheus-card mb-6 text-xs" aria-label="Dependencies">
      <header class="flex flex-wrap items-center gap-x-4 gap-y-1 border-b border-(--orpheus-border) bg-base-200 px-3 py-1.5">
        <h2 class="micro-label flex items-center gap-1.5">
          <.icon name="hero-share-micro" class="size-3.5" /> Dependencies
        </h2>
        <p :if={@parent} id={"#{@id}-parent"} class="flex min-w-0 items-center gap-1.5">
          <span class="micro-label">Sub-task of</span>
          <.task_link task={@parent} />
        </p>
      </header>

      <div class="grid md:grid-cols-2">
        <div class="border-(--orpheus-border) max-md:border-b md:border-r">
          <h3 class="micro-label flex items-center gap-2 px-3 pt-2.5 pb-1.5">
            Blocked by <span class="tabular-nums">[{pad(length(@blockers))}]</span>
            <span
              :if={Enum.any?(@blockers, &(&1.status not in [:done, :canceled]))}
              class="text-error normal-case tracking-normal"
            >
              — agents wait
            </span>
          </h3>
          <ul id={"#{@id}-blockers"}>
            <li
              :for={blocker <- @blockers}
              id={"#{@id}-blocker-#{blocker.id}"}
              class="group flex items-center gap-2 border-t border-dashed border-(--orpheus-border) px-3 py-1.5 transition-colors hover:bg-(--orpheus-hover)"
            >
              <.task_link task={blocker} />
              <span class="ml-auto"><.status_badge status={blocker.status} /></span>
              <button
                type="button"
                id={"#{@id}-remove-#{blocker.id}"}
                phx-click="remove_blocker"
                phx-value-id={blocker.id}
                phx-target={@myself}
                title={"Stop waiting on #{blocker.title}"}
                aria-label={"Remove blocker #{blocker.title}"}
                class="px-1 text-(--orpheus-text-muted) transition-colors hover:text-error"
              >
                <.icon name="hero-x-mark-micro" class="size-3.5" />
              </button>
            </li>
          </ul>
          <.form
            for={@blocker_form}
            id={"#{@id}-blocker-form"}
            phx-submit="add_blocker"
            phx-target={@myself}
            class="flex items-start gap-1.5 border-t border-dashed border-(--orpheus-border) px-3 pt-2 [&>.fieldset]:min-w-0 [&>.fieldset]:flex-1"
          >
            <.input
              field={@blocker_form[:blocker_id]}
              id={"#{@id}-blocker-select"}
              type="select"
              options={@choices}
              prompt="Wait on a task…"
              aria-label="Task this one waits on"
              class="select select-xs w-full min-w-0 font-mono"
            />
            <button id={"#{@id}-add-blocker"} class="btn btn-xs btn-outline shrink-0">+ Block</button>
          </.form>
          <p
            :if={@dependents != []}
            id={"#{@id}-dependents"}
            class="px-3 pb-2.5 text-(--orpheus-text-muted)"
          >
            <span class="micro-label">Blocks</span>
            <span :for={dependent <- @dependents} class="ml-1.5 inline-flex">
              <.task_link task={dependent} />
            </span>
          </p>
        </div>

        <div>
          <h3 class="micro-label flex items-center gap-2 px-3 pt-2.5 pb-1.5">
            Sub-tasks
            <.subtask_progress
              :if={@children != []}
              id={"#{@id}-progress"}
              done={done_count(@children)}
              total={length(open_children(@children))}
            />
          </h3>
          <ul id={"#{@id}-children"}>
            <li
              :for={child <- @children}
              id={"#{@id}-child-#{child.id}"}
              class="flex items-center gap-2 border-t border-dashed border-(--orpheus-border) px-3 py-1.5 transition-colors hover:bg-(--orpheus-hover)"
            >
              <.icon
                name={if child.status == :done, do: "hero-check-micro", else: "hero-minus-micro"}
                class={[
                  "size-3.5 shrink-0",
                  if(child.status == :done, do: "text-success", else: "text-(--orpheus-text-muted)")
                ]}
              />
              <.task_link task={child} />
              <span class="ml-auto"><.status_badge status={child.status} /></span>
            </li>
          </ul>
          <.form
            for={@subtask_form}
            id={"#{@id}-subtask-form"}
            phx-submit="add_subtask"
            phx-target={@myself}
            class="flex items-start gap-1.5 border-t border-dashed border-(--orpheus-border) px-3 pt-2 [&>.fieldset]:min-w-0 [&>.fieldset]:flex-1"
          >
            <.input
              field={@subtask_form[:title]}
              id={"#{@id}-subtask-title"}
              placeholder="New sub-task title"
              aria-label="Sub-task title"
              maxlength="200"
              required
              class="input input-xs w-full min-w-0"
            />
            <button id={"#{@id}-add-subtask"} class="btn btn-xs btn-outline shrink-0">+ Sub-task</button>
          </.form>
        </div>
      </div>

      <p
        :if={@error}
        id={"#{@id}-error"}
        role="alert"
        class="border-t border-(--orpheus-border) px-3 py-1.5 text-error"
      >
        {@error}
      </p>
    </section>
    """
  end

  attr :task, :map, required: true

  defp task_link(assigns) do
    ~H"""
    <.link
      navigate={~p"/tasks/#{@task.id}"}
      class="flex min-w-0 items-baseline gap-1.5 transition-colors hover:text-primary"
    >
      <span class="shrink-0 text-(--orpheus-text-muted)">#{short_id(@task)}</span>
      <span class="truncate">{@task.title}</span>
    </.link>
    """
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
