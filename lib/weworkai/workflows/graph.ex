defmodule Weworkai.Workflows.Graph do
  @moduledoc """
  A workflow's blocks and arrows as one value (docs/workflows.md). `validate/2` builds it
  from an editor's params and checks the whole graph, returning every problem by the
  block or arrow id it belongs to; `new/3` builds it from stored records, which passed that
  check. Routing a block's outcome to its next arrow (`route/4`) is pure: the engine only
  acts on the answer.

  Groups are walked as two points, in (arrows into the group, then its entry block) and out
  (its exit blocks, then the group's own arrows), so a group never looks like a loop. An
  exit is a block with an outcome none of its own arrows takes: inside a group that outcome
  leaves by the group's arrows, so a review loop drawn inside a group still ends it.
  """
  alias Weworkai.Agents.Agent.Role
  alias Weworkai.Board.Task.Status
  alias Weworkai.Workflows.{Edge, Node}
  alias Weworkai.Workflows.Edge.Port
  alias Weworkai.Workflows.Node.{Color, Kind}

  @enforce_keys [:nodes, :edges, :roles, :start_id]
  defstruct [:nodes, :edges, :roles, :start_id]

  @type id :: String.t()
  @type t :: %__MODULE__{
          nodes: %{id() => Node.t()},
          edges: [Edge.t()],
          roles: %{id() => Role.t()},
          start_id: id()
        }
  @type problem :: %{id: id() | nil, message: String.t()}
  @type counts :: %{edges: %{id() => pos_integer()}, nodes: %{id() => pos_integer()}}
  # Employees blocks may name, by id: what they are and, for an agent, its role.
  @type employees :: %{id() => %{kind: :agent | :human, role: Role.t() | nil}}

  @outcomes %{
    planner: ~w(plan_ready needs_answers),
    coder: ~w(done blocked),
    reviewer: ~w(clean findings),
    qa: ~w(clean findings),
    merger: ~w(merged blocked),
    custom: ~w(done)
  }

  @severities [:high, :medium, :low]
  @triage_outcomes Enum.map(@severities, &to_string/1) ++ ["clean"]

  # Outcomes that wait for a human's answers on the same block unless an arrow takes them.
  @pausing ~w(needs_answers blocked)

  @all_outcomes @outcomes |> Map.values() |> List.flatten() |> Enum.uniq()

  @doc "The outcomes an agent block in `role` ends with, which its arrows can name."
  def outcomes(role), do: Map.fetch!(@outcomes, role)

  @doc "The outcomes a triage block ends with, which its arrows can name."
  def triage_outcomes, do: @triage_outcomes

  @doc "A triage block's outcome: the worst severity among the open findings, else `:clean`."
  def triage(findings) do
    Enum.find(@severities, :clean, fn severity ->
      Enum.any?(findings, &(&1.severity == severity))
    end)
  end

  @doc """
  Whether `name` can be a git branch (`git check-ref-format --branch`): letters, digits,
  `.`, `_`, `-` and `/` between parts, no `..`, no part starting with `.` or ending with
  `.lock`, not starting with `-` or `/`, not ending with `/` or `.`, and not `HEAD`.
  """
  def branch_name?(name) when is_binary(name),
    do:
      Regex.match?(
        ~r{\A(?![-/.])(?!HEAD\z)(?!.*(?:\.\.|//|/\.|\.lock(?:/|\z)))[A-Za-z0-9._/-]+(?<![/.])\z},
        name
      )

  def branch_name?(_name), do: false

  ## Building

  @doc "A graph from stored blocks and arrows, which `validate/2` already checked."
  @spec new([Node.t()], [Edge.t()], %{id() => Role.t()}) :: t()
  def new(nodes, edges, roles) do
    %__MODULE__{
      nodes: Map.new(nodes, &{&1.id, &1}),
      edges: edges,
      roles: roles,
      start_id: start_id(nodes, edges)
    }
  end

  @doc """
  Casts the editor's `%{nodes: [...], edges: [...]}` (atom or string keys; arrows name
  their ends as `from` and `to`) and checks the graph: one start block, every block
  reachable from it, groups with exactly one entry block and no nesting in themselves,
  self-loops and back arrows with iterations, human blocks with named arrows, arrow
  conditions an agent's role can end with, agent and human blocks naming employees of
  their kind. Every problem comes back with the id of its block or arrow (nil for the
  workflow as a whole).
  """
  @spec validate(map(), employees()) :: {:ok, t()} | {:error, [problem()]}
  def validate(params, employees) do
    case draft(params, employees) do
      {:ok, graph, []} -> {:ok, graph}
      {:ok, _graph, problems} -> {:error, problems}
      {:error, problems} -> {:error, problems}
    end
  end

  @doc """
  Like `validate/2`, but a graph with problems still comes back, with them, as long as it
  can be stored: every field cast, ids unique, arrows ending on its blocks and blocks
  inside groups that don't contain themselves. A workflow saved so runs no task until
  its problems are fixed.
  """
  @spec draft(map(), employees()) :: {:ok, t(), [problem()]} | {:error, [problem()]}
  def draft(params, employees) do
    params = stringify(params)

    with {:ok, nodes} <- cast_all(params["nodes"] || [], &cast_node/1),
         {:ok, edges} <- cast_all(params["edges"] || [], &cast_edge/1),
         [] <- duplicate_ids(nodes) ++ duplicate_ids(edges) do
      roles = roles(nodes, employees)
      problems = check(nodes, edges, employees, roles)

      if storable?(nodes, edges),
        do: {:ok, new(nodes, edges, roles), problems},
        else: {:error, problems}
    else
      {:error, problems} -> {:error, problems}
      problems -> {:error, problems}
    end
  end

  # The foreign keys hold and a group's depth is finite.
  defp storable?(nodes, edges) do
    by_id = Map.new(nodes, &{&1.id, &1})

    Enum.all?(edges, &(by_id[&1.from_node_id] && by_id[&1.to_node_id])) and
      Enum.all?(nodes, &is_nil(group_problem(&1, by_id)))
  end

  defp roles(nodes, employees) do
    for %{kind: :agent} = node <- nodes,
        role when not is_nil(role) <- [
          node.agent_role || get_in(employees, [node.employee_id, :role])
        ],
        into: %{},
        do: {node.id, role}
  end

  ## Casting

  @node_fields [
    {:kind, Kind, :required},
    {:label, :string, :required},
    {:employee_id, :uuid, nil},
    {:agent_role, Role, nil},
    {:column_status, Status, nil},
    {:group_id, :string, nil},
    {:x, :integer, 0},
    {:y, :integer, 0},
    {:width, :integer, nil},
    {:height, :integer, nil},
    {:start, :boolean, false},
    {:color, Color, nil},
    {:prompt, {:string, max_length: 20_000}, nil},
    {:stall_timeout_minutes, {:integer, min: 1, max: 1440}, nil},
    {:turn_timeout_minutes, {:integer, min: 1, max: 1440}, nil},
    {:merge_branch, {:string, max_length: 255}, nil}
  ]

  @edge_fields [
    {:from, :string, :required},
    {:to, :string, :required},
    {:condition, :string, nil},
    {:iterations, :integer, nil},
    {:from_port, Port, :right},
    {:to_port, Port, :left},
    {:pinned, :boolean, false}
  ]

  defp cast_all(items, cast) do
    {cast, problems} =
      items |> Enum.map(&cast.(stringify(&1))) |> Enum.split_with(&match?({:ok, _}, &1))

    case problems do
      [] -> {:ok, Enum.map(cast, fn {:ok, item} -> item end)}
      _ -> {:error, Enum.map(problems, fn {:error, problem} -> problem end)}
    end
  end

  defp cast_node(params) do
    with {:ok, id, fields} <- cast_fields(params, @node_fields) do
      {:ok, struct!(Node, Map.put(fields, :id, id))}
    end
  end

  defp cast_edge(params) do
    with {:ok, id, fields} <- cast_fields(params, @edge_fields) do
      {from, fields} = Map.pop!(fields, :from)
      {to, fields} = Map.pop!(fields, :to)
      {:ok, struct!(Edge, Map.merge(fields, %{id: id, from_node_id: from, to_node_id: to}))}
    end
  end

  defp cast_fields(params, fields) do
    case blank_to_nil(params["id"]) do
      nil ->
        {:error, %{id: nil, message: "Every block and arrow needs an id"}}

      id ->
        Enum.reduce_while(fields, {:ok, id, %{}}, fn {name, type, default}, {:ok, id, cast} ->
          case cast_field(type, blank_to_nil(params[to_string(name)]), default) do
            {:ok, value} ->
              {:cont, {:ok, id, Map.put(cast, name, value)}}

            :error ->
              {:halt, {:error, %{id: id, message: field_message(name)}}}
          end
        end)
    end
  end

  defp cast_field(_type, nil, :required), do: :error
  defp cast_field(_type, nil, default), do: {:ok, default}

  defp cast_field({type, constraints}, value, _default) do
    with {:ok, cast} <- cast_field(type, value, nil),
         {:ok, cast} <- Ash.Type.apply_constraints(type, cast, constraints) do
      {:ok, cast}
    else
      _invalid -> :error
    end
  end

  defp cast_field(type, value, _default) do
    case Ash.Type.cast_input(type, value, []) do
      {:ok, cast} when not is_nil(cast) -> {:ok, cast}
      _invalid -> :error
    end
  end

  defp field_message(:label), do: "Give the block a name"
  defp field_message(:kind), do: "Unknown kind of block"
  defp field_message(:from), do: "An arrow needs a block to start from"
  defp field_message(:to), do: "An arrow needs a block to point to"
  defp field_message(:iterations), do: "Iterations must be a whole number of at least 1"
  defp field_message(:prompt), do: "Instructions can be at most 20,000 characters"

  defp field_message(limit) when limit in [:stall_timeout_minutes, :turn_timeout_minutes],
    do: "Timeouts must be whole minutes from 1 to 1440"

  defp field_message(:merge_branch), do: "A branch name can be at most 255 characters"

  defp field_message(name), do: "Invalid #{String.replace(to_string(name), "_", " ")}"

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp duplicate_ids(items) do
    items
    |> Enum.frequencies_by(& &1.id)
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(fn {id, _count} -> %{id: id, message: "Two blocks or arrows share this id"} end)
  end

  ## Checks

  defp check(nodes, edges, employees, roles) do
    by_id = Map.new(nodes, &{&1.id, &1})
    {edges, dangling} = Enum.split_with(edges, &(by_id[&1.from_node_id] && by_id[&1.to_node_id]))

    graph = %__MODULE__{
      nodes: by_id,
      edges: edges,
      roles: roles,
      start_id: start_id(nodes, edges)
    }

    problems =
      Enum.map(dangling, &%{id: &1.id, message: "This arrow ends on a block that doesn't exist"}) ++
        Enum.flat_map(nodes, &node_problems(&1, by_id, edges, employees)) ++
        Enum.flat_map(edges, &edge_problems(&1, by_id, roles)) ++
        group_arrow_problems(graph) ++
        duplicate_arrows(edges, by_id)

    case start_problems(nodes, edges) do
      [] -> problems ++ graph_problems(graph)
      start -> problems ++ start
    end
  end

  defp node_problems(node, by_id, edges, employees) do
    [
      settings_problem(node, employees),
      merge_branch_problem(node, employees),
      group_problem(node, by_id),
      if(node.kind == :group, do: entry_problem(node, by_id, edges)),
      if(node.kind == :human, do: decisions_problem(node, edges))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&%{id: node.id, message: &1})
  end

  defp settings_problem(%{kind: :agent} = node, employees) do
    cond do
      node.column_status ->
        "Only column blocks have a column"

      # The editor always sets one: neither means its agent employee was removed.
      is_nil(node.employee_id) and is_nil(node.agent_role) ->
        "Its agent was removed: pick an agent or a role"

      node.employee_id && node.agent_role ->
        "Pick an agent or a role, not both"

      node.employee_id && get_in(employees, [node.employee_id, :kind]) != :agent ->
        "That agent doesn't exist any more"

      true ->
        nil
    end
  end

  defp settings_problem(%{kind: :human} = node, employees) do
    cond do
      node.agent_role || node.column_status ->
        "Only agent blocks have a role"

      node.employee_id && get_in(employees, [node.employee_id, :kind]) != :human ->
        "That person doesn't exist any more"

      true ->
        nil
    end
  end

  defp settings_problem(%{kind: :column} = node, _employees) do
    cond do
      node.employee_id || node.agent_role -> "Column blocks name no employee"
      is_nil(node.column_status) -> "Pick a column"
      true -> nil
    end
  end

  defp settings_problem(%{kind: :group} = node, _employees) do
    if node.employee_id || node.agent_role || node.column_status,
      do: "Groups name no employee or column"
  end

  defp settings_problem(%{kind: :triage} = node, _employees) do
    if node.employee_id || node.agent_role || node.column_status,
      do: "Triage blocks name no employee or column"
  end

  defp merge_branch_problem(%{merge_branch: nil}, _employees), do: nil

  defp merge_branch_problem(node, employees) do
    role = node.agent_role || get_in(employees, [node.employee_id, :role])

    cond do
      node.kind != :agent or role != :merger ->
        "Only merger blocks merge into a branch"

      not branch_name?(node.merge_branch) ->
        "“#{node.merge_branch}” is not a branch name"

      true ->
        nil
    end
  end

  defp group_problem(%{group_id: nil}, _by_id), do: nil

  defp group_problem(node, by_id) do
    cond do
      not match?(%{kind: :group}, by_id[node.group_id]) ->
        "This block is inside something that isn't a group"

      inside_itself?(node, by_id) ->
        "A group can't be inside itself"

      true ->
        nil
    end
  end

  defp inside_itself?(node, by_id),
    do: inside_itself?(node.group_id, node.id, by_id, map_size(by_id))

  defp inside_itself?(nil, _id, _by_id, _steps), do: false
  defp inside_itself?(_group_id, _id, _by_id, 0), do: true
  defp inside_itself?(id, id, _by_id, _steps), do: true

  defp inside_itself?(group_id, id, by_id, steps),
    do: inside_itself?(by_id[group_id] && by_id[group_id].group_id, id, by_id, steps - 1)

  defp entry_problem(group, by_id, edges) do
    case children(by_id, group.id) do
      [] ->
        "A group needs at least one block"

      children ->
        if length(entries(children, edges)) != 1,
          do: "A group needs exactly one first block: the one no arrow inside it points to"
    end
  end

  defp decisions_problem(node, edges) do
    if Enum.all?(edges, &(&1.from_node_id != node.id or is_nil(&1.condition))),
      do: "A human block needs at least one named arrow out: one button per decision"
  end

  defp edge_problems(edge, by_id, roles) do
    from = by_id[edge.from_node_id]

    [
      if(edge.from_node_id == edge.to_node_id and is_nil(edge.iterations),
        do: "A loop needs a number of iterations"
      ),
      condition_problem(from, edge.condition, roles)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&%{id: edge.id, message: &1})
  end

  defp condition_problem(%{kind: :human}, nil, _roles),
    do: "Name this decision: its button shows the name"

  defp condition_problem(%{kind: :column}, condition, _roles) when not is_nil(condition),
    do: "Arrows out of a column take no condition"

  defp condition_problem(%{kind: :triage}, condition, _roles) when not is_nil(condition) do
    if condition not in @triage_outcomes,
      do: "Triage blocks end with #{Enum.join(@triage_outcomes, ", ")}"
  end

  defp condition_problem(%{kind: :agent, id: id}, condition, roles) when not is_nil(condition) do
    case roles[id] do
      nil ->
        nil

      role ->
        if condition not in outcomes(role),
          do: "#{Role.label(role)} blocks end with #{Enum.join(outcomes(role), " or ")}"
    end
  end

  defp condition_problem(_from, _condition, _roles), do: nil

  # A group's named arrow is only taken by an outcome that leaves the group.
  defp group_arrow_problems(graph) do
    for %{condition: condition} = edge when not is_nil(condition) <- graph.edges,
        %{kind: :group} = group <- [graph.nodes[edge.from_node_id]],
        children(graph.nodes, group.id) != [],
        endings = group_endings(graph, group.id, []),
        condition not in endings do
      %{id: edge.id, message: leaves_message(group, condition, Enum.reject(endings, &is_nil/1))}
    end
  end

  defp leaves_message(group, condition, []),
    do: "Nothing leaves #{group.label} with “#{condition}”: its blocks' arrows take every outcome"

  defp leaves_message(group, condition, endings),
    do:
      "Nothing leaves #{group.label} with “#{condition}”: its blocks leave it with " <>
        Enum.join(endings, " or ")

  defp duplicate_arrows(edges, by_id) do
    edges
    |> Enum.group_by(&{&1.from_node_id, &1.from_node_id == &1.to_node_id, &1.condition})
    |> Enum.flat_map(fn {{from, _loop?, condition}, [_first | rest]} ->
      Enum.map(rest, fn edge ->
        %{
          id: edge.id,
          message: "#{by_id[from].label} already has an arrow for #{condition_label(condition)}"
        }
      end)
    end)
  end

  defp condition_label(nil), do: "any other outcome"
  defp condition_label(condition), do: "“#{condition}”"

  defp start_problems([], _edges), do: [%{id: nil, message: "Add a first block"}]

  defp start_problems(nodes, edges) do
    case Enum.filter(nodes, & &1.start) do
      [_start] ->
        []

      [] ->
        if start_id(nodes, edges),
          do: [],
          else: [%{id: nil, message: "Mark one block as the start"}]

      starts ->
        Enum.map(starts, &%{id: &1.id, message: "Only one block can be the start"})
    end
  end

  # Unreachable blocks, then back arrows without a cap (a human deciding each time needs none).
  defp graph_problems(graph) do
    adjacency = adjacency(graph)
    depths = depths(adjacency, entering(graph, graph.start_id))

    unreachable =
      for {id, node} <- graph.nodes, not Map.has_key?(depths, entering(graph, id)) do
        %{id: node.id, message: "This block can't be reached from the start block"}
      end

    uncapped =
      for edge <- graph.edges,
          edge.from_node_id != edge.to_node_id,
          is_nil(edge.iterations),
          graph.nodes[edge.from_node_id].kind != :human,
          back_arrow?(graph, adjacency, depths, edge) do
        %{
          id: edge.id,
          message: "An arrow back to an earlier block needs a maximum number of times"
        }
      end

    unreachable ++ uncapped
  end

  defp back_arrow?(graph, adjacency, depths, edge) do
    from = leaving(graph, edge.from_node_id)
    to = entering(graph, edge.to_node_id)

    Map.has_key?(depths, from) and Map.has_key?(depths(adjacency, to), from) and
      depths[to] <= depths[from]
  end

  ## Walking

  defp entering(graph, id), do: if(graph.nodes[id].kind == :group, do: {:in, id}, else: id)
  defp leaving(graph, id), do: if(graph.nodes[id].kind == :group, do: {:out, id}, else: id)

  # Points: a block's id, or {:in, id} / {:out, id} for a group.
  defp adjacency(graph) do
    arrows =
      Enum.map(graph.edges, &{leaving(graph, &1.from_node_id), entering(graph, &1.to_node_id)})

    groups =
      for {id, %{kind: :group}} <- graph.nodes,
          children <- [children(graph.nodes, id)],
          [entry] <- [entries(children, graph.edges)],
          pair <- [{{:in, id}, entering(graph, entry.id)} | exits(graph, children, id)],
          do: pair

    Enum.group_by(arrows ++ groups, &elem(&1, 0), &elem(&1, 1))
  end

  defp exits(graph, children, group_id) do
    for child <- children,
        Enum.any?(unrouted(graph, child.id, []), &leaves?(graph, group_id, &1)),
        do: {leaving(graph, child.id), {:out, group_id}}
  end

  ## Leaving groups
  # `seen`: the groups on the way down, so a group drawn inside itself (a graph that can't
  # be stored, only checked) ends the walk.

  # What the block can end with: its role's outcomes (any, its agent removed), a triage
  # block's severities, nil (no
  # outcome) for a column or a human without decisions, a group's what leaves it. A
  # human's decisions are its arrows, so they never go unrouted.
  defp endings(graph, id, seen) do
    case graph.nodes[id] do
      %{kind: :agent} -> if role = graph.roles[id], do: outcomes(role), else: @all_outcomes
      %{kind: :human} -> if departures(graph.edges, id) == [], do: [nil], else: []
      %{kind: :column} -> [nil]
      %{kind: :triage} -> @triage_outcomes
      %{kind: :group} -> group_endings(graph, id, seen)
    end
  end

  defp group_endings(graph, group_id, seen) do
    if group_id in seen do
      []
    else
      graph.nodes
      |> children(group_id)
      |> Enum.flat_map(&unrouted(graph, &1.id, [group_id | seen]))
      |> Enum.filter(&leaves?(graph, group_id, &1))
      |> Enum.uniq()
    end
  end

  # The block's endings none of its own arrows takes for good: an arrow with a cap can run
  # out, and then only the one arrow left (route/4, rule 4) still takes it.
  defp unrouted(graph, id, seen) do
    {capped, uncapped} = graph.edges |> departures(id) |> Enum.split_with(& &1.iterations)

    Enum.reject(endings(graph, id, seen), fn outcome ->
      Enum.any?(uncapped, &takes?(&1, outcome)) or
        (Enum.any?(capped, &takes?(&1, outcome)) and match?([_], uncapped))
    end)
  end

  defp takes?(edge, outcome) when outcome in @pausing, do: edge.condition == outcome
  defp takes?(edge, outcome), do: edge.condition in [nil, outcome]

  # A pausing outcome waits on its block unless an arrow names it.
  defp leaves?(graph, group_id, outcome),
    do: outcome not in @pausing or named?(graph, group_id, outcome)

  defp depths(adjacency, from), do: breadth_first(adjacency, [from], %{from => 0})

  defp breadth_first(_adjacency, [], depths), do: depths

  defp breadth_first(adjacency, [point | queue], depths) do
    next = Enum.reject(Map.get(adjacency, point, []), &Map.has_key?(depths, &1))
    depths = Enum.reduce(next, depths, &Map.put(&2, &1, depths[point] + 1))
    breadth_first(adjacency, queue ++ Enum.uniq(next), depths)
  end

  defp children(nodes, group_id) when is_map(nodes),
    do: nodes |> Map.values() |> Enum.filter(&(&1.group_id == group_id)) |> sort_by_place()

  # A group's entry: the child no arrow from a sibling points to. With a loop drawn inside
  # it (Reviewer findings → Coder) every child can have one: then the first drawn of those
  # that reach every sibling.
  defp entries(children, edges) do
    ids = MapSet.new(children, & &1.id)

    inner =
      Enum.filter(
        edges,
        &(&1.from_node_id in ids and &1.to_node_id in ids and &1.from_node_id != &1.to_node_id)
      )

    case Enum.reject(children, fn child -> Enum.any?(inner, &(&1.to_node_id == child.id)) end) do
      [] -> children |> Enum.filter(&reaches_all?(&1.id, inner, ids)) |> Enum.take(1)
      entries -> entries
    end
  end

  defp reaches_all?(id, inner, ids) do
    adjacency = Enum.group_by(inner, & &1.from_node_id, & &1.to_node_id)
    adjacency |> depths(id) |> Map.keys() |> MapSet.new() |> MapSet.equal?(ids)
  end

  defp departures(edges, id),
    do: Enum.filter(edges, &(&1.from_node_id == id and &1.to_node_id != id))

  defp start_id(nodes, edges) do
    case Enum.find(nodes, & &1.start) do
      nil ->
        case Enum.filter(nodes, &(is_nil(&1.group_id) and arrivals(edges, &1.id) == [])) do
          [start] -> start.id
          _none_or_several -> nil
        end

      start ->
        start.id
    end
  end

  defp arrivals(edges, id),
    do: Enum.filter(edges, &(&1.to_node_id == id and &1.from_node_id != id))

  defp sort_by_place(nodes), do: Enum.sort_by(nodes, &{&1.x, &1.y, &1.label})

  ## Reading

  def node(graph, id), do: Map.get(graph.nodes, id)
  def start(graph), do: graph.nodes[graph.start_id]

  @doc "An agent block's role: its own, or its employee's agent's."
  def role(graph, id), do: graph.roles[id]

  @doc "The arrows leaving the block, loops included, in the order their targets are drawn."
  def outgoing(graph, id) do
    graph.edges
    |> Enum.filter(&(&1.from_node_id == id))
    |> Enum.sort_by(&{graph.nodes[&1.to_node_id].x, graph.nodes[&1.to_node_id].y})
  end

  @doc """
  The block entering `id` runs, and the groups entered on the way (outermost first): a
  group starts its entry block.
  """
  @spec resolve(t(), id()) :: {Node.t(), [Node.t()]}
  def resolve(graph, id), do: resolve(graph, graph.nodes[id], [])

  # A group without exactly one entry only exists in a workflow saved with problems, which
  # runs no task: the group stands for itself, or for its first entry.
  defp resolve(graph, %{kind: :group} = group, groups) do
    case entries(children(graph.nodes, group.id), graph.edges) do
      [] -> {group, groups}
      [entry | _others] -> resolve(graph, entry, groups ++ [group])
    end
  end

  defp resolve(_graph, node, groups), do: {node, groups}

  @doc "The ids of the groups the block is inside, outermost first."
  def groups_around(graph, id) do
    case graph.nodes[id].group_id do
      nil -> []
      group_id -> groups_around(graph, group_id) ++ [group_id]
    end
  end

  @doc "Every block, in the order a walk from the start meets them; unreachable ones last."
  def order(%{start_id: nil} = graph), do: graph.nodes |> Map.values() |> sort_by_place()

  def order(graph) do
    met =
      graph
      |> adjacency()
      |> depths(entering(graph, graph.start_id))
      |> Enum.sort_by(fn {point, depth} -> {depth, place(graph, point)} end)
      |> Enum.flat_map(fn
        {{:out, _id}, _depth} -> []
        {{:in, id}, _depth} -> [id]
        {id, _depth} -> [id]
      end)

    rest = graph.nodes |> Map.drop(met) |> Map.values() |> sort_by_place()
    Enum.map(met, &graph.nodes[&1]) ++ rest
  end

  defp place(graph, {_side, id}), do: place(graph, id)
  defp place(graph, id), do: {graph.nodes[id].x, graph.nodes[id].y}

  ## Routing

  @doc "Whether a capped arrow was taken as often as it may be."
  def exhausted?(%{iterations: nil}, _edge_counts), do: false
  def exhausted?(edge, edge_counts), do: Map.get(edge_counts, edge.id, 0) >= edge.iterations

  @doc """
  Where the block's `outcome` (nil: none, as a column ends) leads:

  1. `needs_answers` / `blocked` with no arrow named so (nor one of the groups around the
     block) → `:pause` on the block; unnamed arrows never take them.
  2. a self-loop for the outcome (or any) while the block ran fewer times in a row than its
     iterations.
  3. the arrow named for the outcome, unless exhausted; else the unnamed (`always`) one.
  4. falling out of an exhausted loop or capped arrow: the one arrow left, if exactly one
     (for an outcome leaving a group: the group's one arrow left).
  5. nothing of the block's own fits, inside a group: the group's arrows (the outcome ends
     the group), so Reviewer `findings` → Coder inside a group leaves it on `clean`.

  `:none` when nothing fits.
  """
  @spec route(t(), id(), atom() | nil, counts()) :: {:follow, Edge.t()} | :pause | :none
  def route(graph, id, outcome, counts), do: route(graph, id, outcome, counts, false)

  # `spent?`: the outcome leaves a group block whose arrow for it ran out (rule 4).
  defp route(graph, id, outcome, counts, spent?) do
    label = outcome && to_string(outcome)
    arrows = outgoing(graph, id)
    {loops, others} = Enum.split_with(arrows, &(&1.to_node_id == id))
    open = Enum.reject(others, &exhausted?(&1, counts.edges))
    # A block being routed ran at least once; a group has no count when a human started
    # the task on one of its blocks directly (drag into review, Continue).
    runs = Map.get(counts.nodes, id, 1)
    fits? = &(&1.condition in [nil, label])
    group_id = graph.nodes[id].group_id

    cond do
      label in @pausing and not named?(graph, id, label) ->
        :pause

      label in @pausing and not Enum.any?(arrows, &(&1.condition == label)) ->
        route(graph, group_id, outcome, counts, spent?)

      loop = Enum.find(loops, &(fits?.(&1) and runs < &1.iterations)) ->
        {:follow, loop}

      named = Enum.find(open, &(&1.condition == label and not is_nil(label))) ->
        {:follow, named}

      always = Enum.find(open, &is_nil(&1.condition)) ->
        {:follow, always}

      (spent? or Enum.any?(arrows, fits?)) and match?([_], open) ->
        {:follow, hd(open)}

      group_id ->
        route(graph, group_id, outcome, counts, spent? or Enum.any?(arrows, fits?))

      true ->
        :none
    end
  end

  # An arrow out of the block, or out of a group around it, names `label`.
  defp named?(graph, id, label) do
    group_id = graph.nodes[id].group_id

    Enum.any?(outgoing(graph, id), &(&1.condition == label)) or
      (group_id != nil and named?(graph, group_id, label))
  end
end
