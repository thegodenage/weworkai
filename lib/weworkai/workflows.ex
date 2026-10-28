defmodule Weworkai.Workflows do
  @moduledoc """
  User-defined workflows (docs/workflows.md): graphs of blocks and arrows a task runs
  through, interpreted by `Weworkai.Workflows.Engine`. A graph is only ever written
  whole (`save_graph/2`), with the problems `Graph.draft/2` finds in it.
  """
  use Ash.Domain, otp_app: :weworkai, extensions: [AshPhoenix]

  require Ash.Query

  alias Weworkai.Organization
  alias Weworkai.Workflows.{Edge, Graph, Node, Version, Workflow}

  resources do
    resource Workflow do
      define :list_workflows, action: :list
      define :list_templates, action: :templates
      define :get_workflow, action: :read, get_by: [:id]
      define :search_workflows, action: :search, args: [:pattern]
      define :create_workflow, action: :create, args: [:name, {:optional, :source_id}]
      define :rename_workflow, action: :rename, args: [:name]
      define :reposition_workflow, action: :reposition, args: [:position]
      define :record_graph, action: :record_graph, args: [:problem_count]
      define :recount_workflow, action: :recount, args: [:problem_count]
      define :destroy_workflow, action: :destroy
    end

    resource Node
    resource Edge

    resource Version do
      define :list_versions, action: :history, args: [:workflow_id]
      define :get_version, action: :read, get_by: [:workflow_id, :number]
    end
  end

  @doc "The workflow new tasks run unless they pick another: the first in the list."
  def default_workflow! do
    Workflow
    |> Ash.Query.sort(position: :asc, inserted_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!()
  end

  @doc "The workflow's blocks and arrows, as stored."
  @spec graph!(String.t()) :: Graph.t()
  def graph!(workflow_id) do
    nodes =
      Node
      |> Ash.Query.filter(workflow_id == ^workflow_id)
      |> Ash.Query.load(employee: :agent)
      |> Ash.read!()

    edges = Edge |> Ash.Query.filter(workflow_id == ^workflow_id) |> Ash.read!()
    Graph.new(nodes, edges, roles(nodes))
  end

  defp roles(nodes) do
    for %{kind: :agent} = node <- nodes,
        role when not is_nil(role) <- [node.agent_role || employee_role(node.employee)],
        into: %{},
        do: {node.id, role}
  end

  defp employee_role(%{agent: %{role: role}}), do: role
  defp employee_role(_none), do: nil

  @doc """
  Replaces the workflow's graph with the editor's `%{nodes: [...], edges: [...]}` in one
  transaction, problems and all (`Graph.draft/2`): the workflow records how many it has,
  and runs no task until they are fixed. Only a graph that can't be stored at all (arrows
  to missing blocks…) changes nothing and comes back as its problems by block or arrow id.
  `workflow.version` is the version the graph was edited from: when the workflow was saved
  since, nothing changes either (`:stale`).

  Ids the workflow already has are kept, so tasks keep their place and traversal counts;
  any other id (the editor's own, like "n1") gets a new uuid. `ids` maps each id sent to
  the one stored.
  """
  @spec save_graph(Workflow.t(), map()) ::
          {:ok,
           %{
             workflow: Workflow.t(),
             ids: %{String.t() => String.t()},
             problems: [Graph.problem()]
           }}
          | {:error, :stale | [Graph.problem()]}
  def save_graph(workflow, params), do: save_graph(workflow, params, [])

  # `kept`: ids to keep besides the workflow's own (a restored version's).
  defp save_graph(workflow, params, kept) do
    with {:ok, graph, problems} <- Graph.draft(params, employees()) do
      current = graph!(workflow.id)
      known = MapSet.new(Map.keys(current.nodes) ++ Enum.map(current.edges, & &1.id) ++ kept)
      ids = Map.new(ids(graph), &{&1, if(&1 in known, do: &1, else: Ecto.UUID.generate())})

      # The version check comes first: a stale save writes nothing.
      Ash.transact([Workflow, Node, Edge, Version], fn ->
        case record_graph(workflow, length(problems)) do
          {:ok, saved} ->
            replace!(workflow.id, graph, ids)
            record_version!(saved)
            %{workflow: saved, ids: ids, problems: problems}

          {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{} | _]}} ->
            :stale
        end
      end)
      |> case do
        {:ok, :stale} -> {:error, :stale}
        {:ok, saved} -> {:ok, saved}
      end
    end
  end

  defp replace!(workflow_id, graph, ids) do
    Edge
    |> Ash.Query.filter(workflow_id == ^workflow_id)
    |> Ash.bulk_destroy!(:destroy, %{})

    Node
    |> Ash.Query.filter(workflow_id == ^workflow_id)
    |> Ash.bulk_destroy!(:destroy, %{})

    insert!(workflow_id, graph, ids)
  end

  @doc "The problems a graph in the editor's params has; [] when none."
  @spec problems(map()) :: [Graph.problem()]
  def problems(params) do
    case Graph.draft(params, employees()) do
      {:ok, _graph, problems} -> problems
      {:error, problems} -> problems
    end
  end

  @doc """
  Counts every workflow's problems again, for a change outside the editor that can add or
  fix some: an employee its blocks name was removed (the block names nobody now) or an
  agent changed role (its arrows' outcomes). The list's badge and the refusal to run
  tasks follow the count.
  """
  def recount_problems! do
    for workflow <- list_workflows!(),
        count = length(problems(params(graph!(workflow.id)))),
        count != workflow.problem_count,
        do: recount_workflow!(workflow, count)

    :ok
  end

  @doc "`recount_problems!/0` as an Ash `after_action` callback."
  def recount_after(_changeset, record, _context) do
    recount_problems!()
    {:ok, record}
  end

  @doc "A stored graph in the editor's shape: the params `save_graph/2` and `problems/1` take."
  def params(graph) do
    %{
      nodes:
        Enum.map(Map.values(graph.nodes), fn node ->
          Map.take(node, [
            :id,
            :kind,
            :label,
            :employee_id,
            :agent_role,
            :column_status,
            :group_id,
            :x,
            :y,
            :width,
            :height,
            :start,
            :color,
            :prompt,
            :stall_timeout_minutes,
            :turn_timeout_minutes,
            :merge_branch
          ])
        end),
      edges:
        Enum.map(graph.edges, fn edge ->
          edge
          |> Map.take([:id, :condition, :iterations, :from_port, :to_port, :pinned])
          |> Map.merge(%{from: edge.from_node_id, to: edge.to_node_id})
        end)
    }
  end

  @doc "Why a version with problems (`running!/1`) runs no task, for the refusal and the stall."
  def not_runnable(%{workflow: workflow, problems: problems}) do
    problems = if length(problems) == 1, do: "a problem", else: "#{length(problems)} problems"

    "The workflow “#{workflow.name}” has #{problems} to fix in its editor before tasks can run it."
  end

  ## Versions

  @doc "Records the workflow's stored graph as its version `workflow.version`."
  def record_version!(workflow) do
    Ash.create!(Version, %{
      workflow_id: workflow.id,
      number: workflow.version,
      graph: params(graph!(workflow.id)),
      problem_count: workflow.problem_count
    })
  end

  @doc """
  The version a task runs on: the one it is pinned to while it is on a block, else (not
  started, ended, switched) its workflow's latest, which the step it takes then pins.
  """
  def running_version(%{current_node_id: nil}, workflow), do: workflow.version
  def running_version(task, _workflow), do: task.workflow_version

  @doc """
  What a task runs on (`running_version/2`): its workflow, the version's number, its graph
  and the problems it has with today's employees (a task runs none with problems).
  """
  def running!(task) do
    workflow = get_workflow!(task.workflow_id)
    number = running_version(task, workflow)
    {graph, problems} = restore(get_version!(workflow.id, number))
    %{workflow: workflow, version: number, graph: graph, problems: problems}
  end

  @doc """
  Whether a task pinned to an older version can move to its workflow's latest: `{:ok,
  number}` when the latest runs and has the block the task is on, else why not.
  """
  @spec upgrade(map()) :: {:ok, pos_integer()} | {:error, String.t()}
  def upgrade(task) do
    workflow = get_workflow!(task.workflow_id)
    {graph, problems} = restore(get_version!(workflow.id, workflow.version))
    running = %{workflow: workflow, problems: problems}

    cond do
      problems != [] ->
        {:error, not_runnable(running)}

      is_nil(Graph.node(graph, task.current_node_id)) ->
        {:error,
         "Its block is not in v#{workflow.version}: it finishes on v#{task.workflow_version}."}

      true ->
        {:ok, workflow.version}
    end
  end

  @doc """
  Saves `version`'s graph as the workflow's newest version: a rollback that keeps the
  history. Its blocks keep their ids, so tasks pinned to it can move to the new one.
  """
  def restore_version(workflow, version) do
    graph = version.graph
    save_graph(workflow, graph, Enum.map(graph["nodes"] ++ graph["edges"], & &1["id"]))
  end

  @doc "The blocks of a version by id, for labelling where tasks are."
  def version_nodes(workflow_id, number) do
    {graph, _problems} = restore(get_version!(workflow_id, number))
    graph.nodes
  end

  @doc "How many of the workflow's tasks are on a block of each of its versions."
  def pinned_counts(workflow_id) do
    Weworkai.Board.Task
    |> Ash.Query.filter(workflow_id == ^workflow_id and not is_nil(current_node_id))
    |> Ash.Query.select([:workflow_version])
    |> Ash.read!()
    |> Enum.frequencies_by(& &1.workflow_version)
  end

  # A stored version as a graph, checked against today's employees. A removed employee's
  # blocks name nobody, as stored blocks do (`on_delete: :nilify`).
  defp restore(version) do
    employees = employees()

    nodes =
      Enum.map(version.graph["nodes"], fn node ->
        Map.update!(node, "employee_id", &if(Map.has_key?(employees, &1), do: &1))
      end)

    {:ok, graph, problems} =
      Graph.draft(%{"nodes" => nodes, "edges" => version.graph["edges"]}, employees)

    {graph, problems}
  end

  @doc "Copies `source`'s blocks and arrows into the empty workflow `target`, under new ids."
  def copy_graph!(source, target) do
    graph = graph!(source.id)
    insert!(target.id, graph, Map.new(ids(graph), &{&1, Ecto.UUID.generate()}))
  end

  defp ids(graph), do: Map.keys(graph.nodes) ++ Enum.map(graph.edges, & &1.id)

  # Groups before the blocks inside them, for the foreign key.
  defp insert!(workflow_id, graph, ids) do
    nodes =
      graph.nodes
      |> Map.values()
      |> Enum.sort_by(&depth(graph, &1))
      |> Enum.map(fn node ->
        node
        |> Map.take([
          :kind,
          :employee_id,
          :agent_role,
          :column_status,
          :label,
          :x,
          :y,
          :width,
          :height,
          :start,
          :color,
          :prompt,
          :stall_timeout_minutes,
          :turn_timeout_minutes,
          :merge_branch
        ])
        |> Map.merge(%{id: ids[node.id], workflow_id: workflow_id, group_id: ids[node.group_id]})
      end)

    edges =
      Enum.map(graph.edges, fn edge ->
        edge
        |> Map.take([:condition, :iterations, :from_port, :to_port, :pinned])
        |> Map.merge(%{
          id: ids[edge.id],
          workflow_id: workflow_id,
          from_node_id: ids[edge.from_node_id],
          to_node_id: ids[edge.to_node_id]
        })
      end)

    Ash.bulk_create!(nodes, Node, :create, stop_on_error?: true)
    Ash.bulk_create!(edges, Edge, :create, stop_on_error?: true)
    :ok
  end

  defp depth(_graph, %{group_id: nil}), do: 0
  defp depth(graph, node), do: 1 + depth(graph, graph.nodes[node.group_id])

  defp employees do
    Organization.list_all_employees!(load: :agent)
    |> Map.new(&{&1.id, %{kind: &1.kind, role: &1.agent && &1.agent.role}})
  end

  @doc "Moves the workflow one place up or down the list; the first is the default."
  def move_workflow(workflow, direction) when direction in [:up, :down] do
    workflows = list_workflows!()
    index = Enum.find_index(workflows, &(&1.id == workflow.id))
    other = if direction == :up, do: index - 1, else: index + 1

    if other in 0..(length(workflows) - 1)//1 do
      reordered =
        workflows
        |> List.replace_at(index, Enum.at(workflows, other))
        |> List.replace_at(other, Enum.at(workflows, index))

      {:ok, :ok} =
        Ash.transact(Workflow, fn ->
          reordered
          |> Enum.with_index()
          |> Enum.each(fn {workflow, position} -> reposition_workflow!(workflow, position) end)
        end)
    end

    :ok
  end
end
