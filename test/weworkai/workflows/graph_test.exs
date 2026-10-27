defmodule Weworkai.Workflows.GraphTest do
  use ExUnit.Case, async: true

  alias Weworkai.Workflows.Graph

  @agent_id "00000000-0000-0000-0000-00000000000a"
  @human_id "00000000-0000-0000-0000-00000000000b"
  @employees %{
    @agent_id => %{kind: :agent, role: :coder},
    @human_id => %{kind: :human, role: nil}
  }

  defp agent(id, role, extra \\ %{}),
    do: Map.merge(%{"id" => id, "kind" => "agent", "label" => id, "agent_role" => role}, extra)

  defp human(id, extra \\ %{}),
    do: Map.merge(%{"id" => id, "kind" => "human", "label" => id}, extra)

  defp column(id, status),
    do: %{"id" => id, "kind" => "column", "label" => id, "column_status" => status}

  defp group(id, extra \\ %{}),
    do: Map.merge(%{"id" => id, "kind" => "group", "label" => id}, extra)

  defp arrow(id, from, to, condition \\ nil, iterations \\ nil),
    do: %{
      "id" => id,
      "from" => from,
      "to" => to,
      "condition" => condition,
      "iterations" => iterations
    }

  # Planner → Approve plan → Coder → Reviewer → Docker reviewer → Approve → Done.
  defp default_graph do
    %{
      nodes: [
        agent("planner", "planner", %{"start" => true}),
        human("approve_plan"),
        agent("coder", "coder", %{"x" => 2}),
        agent("reviewer", "reviewer", %{"x" => 3}),
        agent("qa", "qa", %{"x" => 4}),
        human("approve", %{"x" => 5}),
        column("done", "done")
      ],
      edges: [
        arrow("e1", "planner", "approve_plan", "plan_ready"),
        arrow("e2", "approve_plan", "coder", "approved"),
        arrow("e3", "coder", "reviewer", "done"),
        arrow("e4", "reviewer", "qa"),
        arrow("e5", "qa", "coder", "findings", 3),
        arrow("e6", "qa", "approve", "clean"),
        arrow("e7", "approve", "done", "accepted"),
        arrow("e8", "approve", "coder", "continue")
      ]
    }
  end

  # Planner → group {Coder --done--> Reviewer --findings ×3--> Coder} --clean--> Approve → Done.
  defp review_loop_group do
    %{
      nodes: [
        agent("start", "planner", %{"start" => true}),
        group("g", %{"x" => 1}),
        agent("coder", "coder", %{"group_id" => "g", "x" => 2}),
        agent("reviewer", "reviewer", %{"group_id" => "g", "x" => 3}),
        human("approve", %{"x" => 4}),
        column("done", "done")
      ],
      edges: [
        arrow("in", "start", "g", "plan_ready"),
        arrow("inner", "coder", "reviewer", "done"),
        arrow("back", "reviewer", "coder", "findings", 3),
        arrow("out", "g", "approve", "clean"),
        arrow("yes", "approve", "done", "accepted")
      ]
    }
  end

  defp problems(params) do
    assert {:error, problems} = Graph.validate(params, @employees)
    Enum.map(problems, &{&1.id, &1.message})
  end

  defp counts(edges \\ %{}, nodes \\ %{}), do: %{edges: edges, nodes: nodes}

  describe "validate/2" do
    test "the default graph is valid; a human arrow back to the coder needs no cap" do
      assert {:ok, graph} = Graph.validate(default_graph(), @employees)
      assert graph.start_id == "planner"
      assert Graph.role(graph, "qa") == :qa

      assert Enum.map(Graph.order(graph), & &1.id) ==
               ~w(planner approve_plan coder reviewer qa approve done)
    end

    test "string or atom keys, and the start is the one block no arrow points to" do
      params = %{
        nodes: [
          %{id: "a", kind: :agent, label: "A", agent_role: :custom},
          %{id: "b", kind: :column, label: "B", column_status: :done}
        ],
        edges: [%{id: "e", from: "a", to: "b"}]
      }

      assert {:ok, %{start_id: "a"}} = Graph.validate(params, @employees)
    end

    test "an empty graph, or one without a start, is refused for the workflow as a whole" do
      assert problems(%{nodes: [], edges: []}) == [{nil, "Add a first block"}]

      loop = %{
        nodes: [agent("a", "coder"), agent("b", "reviewer")],
        edges: [arrow("e1", "a", "b", "done"), arrow("e2", "b", "a", "findings", 2)]
      }

      assert problems(loop) == [{nil, "Mark one block as the start"}]
    end

    test "only one block can be the start" do
      params = %{
        nodes: [
          agent("a", "custom", %{"start" => true}),
          agent("b", "custom", %{"start" => true})
        ],
        edges: []
      }

      assert [{"a", "Only one block can be the start"}, {"b", "Only one block can be the start"}] =
               problems(params)
    end

    test "a group's arrows name outcomes its blocks can leave it with" do
      params =
        update_in(review_loop_group().edges, &(&1 ++ [arrow("never", "g", "approve", "done")]))

      assert problems(params) == [
               {"never",
                "Nothing leaves g with “done”: its blocks leave it with clean or findings"}
             ]
    end

    test "a review loop inside a group leaves the group: what follows it is reachable" do
      assert {:ok, _graph} = Graph.validate(review_loop_group(), @employees)
    end

    test "every block must be reachable from the start" do
      params = update_in(default_graph().nodes, &(&1 ++ [agent("lonely", "custom")]))
      assert problems(params) == [{"lonely", "This block can't be reached from the start block"}]
    end

    test "self-loops need iterations; back arrows from agents need a cap" do
      params =
        update_in(default_graph().edges, fn edges ->
          edges
          |> Enum.map(&if(&1["id"] == "e5", do: %{&1 | "iterations" => nil}, else: &1))
          |> Kernel.++([arrow("loop", "reviewer", "reviewer")])
        end)

      assert Enum.sort(problems(params)) == [
               {"e5", "An arrow back to an earlier block needs a maximum number of times"},
               {"loop", "A loop needs a number of iterations"}
             ]
    end

    test "a diamond's cross arrow is no back arrow" do
      params = %{
        nodes: [
          agent("a", "planner", %{"start" => true}),
          human("b"),
          human("c", %{"x" => 1}),
          column("d", "done")
        ],
        edges: [
          arrow("e1", "a", "b", "plan_ready"),
          arrow("e2", "b", "c", "go"),
          arrow("e3", "b", "d", "stop"),
          arrow("e4", "c", "d", "go")
        ]
      }

      assert {:ok, _graph} = Graph.validate(params, @employees)
    end

    test "human blocks need named arrows out" do
      params = %{
        nodes: [human("h", %{"start" => true}), human("dead_end"), column("d", "done")],
        edges: [arrow("e1", "h", "d"), arrow("e2", "h", "dead_end", "maybe")]
      }

      assert Enum.sort(problems(params)) == [
               {"dead_end",
                "A human block needs at least one named arrow out: one button per decision"},
               {"e1", "Name this decision: its button shows the name"}
             ]
    end

    test "conditions must be outcomes the agent's role ends with; columns take none" do
      params = %{
        nodes: [
          agent("c", "coder", %{"start" => true}),
          column("col", "review"),
          column("d", "done")
        ],
        edges: [arrow("e1", "c", "col", "clean"), arrow("e2", "col", "d", "go")]
      }

      assert Enum.sort(problems(params)) == [
               {"e1", "Coder blocks end with done or blocked"},
               {"e2", "Arrows out of a column take no condition"}
             ]
    end

    test "triage blocks end with a severity or clean, and name nothing" do
      params = %{
        nodes: [
          agent("r", "reviewer", %{"start" => true}),
          %{"id" => "t", "kind" => "triage", "label" => "Triage", "agent_role" => "coder"},
          column("d", "done")
        ],
        edges: [arrow("e1", "r", "t"), arrow("e2", "t", "d", "findings")]
      }

      assert Enum.sort(problems(params)) == [
               {"e2", "Triage blocks end with high, medium, low, clean"},
               {"t", "Triage blocks name no employee or column"}
             ]
    end

    test "two arrows from one block for the same outcome are ambiguous" do
      params =
        update_in(default_graph().edges, &(&1 ++ [arrow("again", "coder", "reviewer", "done")]))

      assert problems(params) == [{"again", "coder already has an arrow for “done”"}]
    end

    test "agent and human blocks name employees of their kind, or a role / nobody" do
      params = %{
        nodes: [
          agent("a", nil, %{"start" => true}),
          agent("b", "coder", %{"employee_id" => @agent_id}),
          agent("c", nil, %{"employee_id" => @human_id}),
          agent("d", nil, %{"employee_id" => @agent_id}),
          human("h", %{"employee_id" => @agent_id})
        ],
        edges: [
          arrow("e1", "a", "b"),
          arrow("e2", "b", "c"),
          arrow("e3", "c", "d"),
          arrow("e4", "d", "h"),
          arrow("e5", "h", "a", "again")
        ]
      }

      assert Enum.sort(problems(params)) == [
               {"a", "Its agent was removed: pick an agent or a role"},
               {"b", "Pick an agent or a role, not both"},
               {"c", "That agent doesn't exist any more"},
               {"h", "That person doesn't exist any more"}
             ]
    end

    test "groups: non-empty, one entry block, never inside themselves" do
      params = %{
        nodes: [
          agent("start", "custom", %{"start" => true}),
          group("empty"),
          group("two"),
          agent("x", "custom", %{"group_id" => "two"}),
          agent("y", "custom", %{"group_id" => "two"}),
          group("self", %{"group_id" => "self"}),
          agent("z", "custom", %{"group_id" => "self"}),
          agent("w", "custom", %{"group_id" => "x"})
        ],
        edges: [
          arrow("e1", "start", "empty"),
          arrow("e2", "start", "two", nil),
          arrow("e3", "start", "self")
        ]
      }

      found = problems(params)
      assert {"empty", "A group needs at least one block"} in found

      assert {"two",
              "A group needs exactly one first block: the one no arrow inside it points to"} in found

      assert {"self", "A group can't be inside itself"} in found
      assert {"w", "This block is inside something that isn't a group"} in found
    end

    test "blocks and arrows that can't be cast name their id" do
      params = %{
        nodes: [
          %{"id" => "a", "kind" => "robot", "label" => "A"},
          %{"id" => "b", "kind" => "agent"}
        ],
        edges: []
      }

      assert problems(params) == [{"a", "Unknown kind of block"}, {"b", "Give the block a name"}]

      params = %{
        nodes: [agent("a", "custom")],
        edges: [arrow("e", "a", "ghost"), %{"id" => "f", "from" => "a"}]
      }

      assert problems(params) == [{"f", "An arrow needs a block to point to"}]

      params = %{
        nodes: [agent("a", "custom", %{"start" => true})],
        edges: [arrow("e", "a", "ghost")]
      }

      assert problems(params) == [{"e", "This arrow ends on a block that doesn't exist"}]
    end
  end

  describe "route/4" do
    setup do
      {:ok, graph} = Graph.validate(default_graph(), @employees)
      %{graph: graph}
    end

    test "a named arrow for the outcome, else the unnamed one", %{graph: graph} do
      assert {:follow, %{id: "e3"}} = Graph.route(graph, "coder", :done, counts())
      assert {:follow, %{id: "e4"}} = Graph.route(graph, "reviewer", :findings, counts())
      assert {:follow, %{id: "e6"}} = Graph.route(graph, "qa", :clean, counts())
    end

    test "needs_answers and blocked pause on the block unless an arrow names them", %{
      graph: graph
    } do
      assert Graph.route(graph, "planner", :needs_answers, counts()) == :pause
      assert Graph.route(graph, "coder", :blocked, counts()) == :pause
    end

    test "a capped arrow is skipped once exhausted; the one arrow left is the way out", %{
      graph: graph
    } do
      assert {:follow, %{id: "e5"}} = Graph.route(graph, "qa", :findings, counts(%{"e5" => 2}))
      assert {:follow, %{id: "e6"}} = Graph.route(graph, "qa", :findings, counts(%{"e5" => 3}))
    end

    test "a self-loop repeats the block up to its iterations in a row, then falls through" do
      params =
        default_graph()
        |> update_in([:edges], &(&1 ++ [arrow("twice", "reviewer", "reviewer", nil, 2)]))

      {:ok, graph} = Graph.validate(params, @employees)

      assert {:follow, %{id: "twice"}} =
               Graph.route(graph, "reviewer", :clean, counts(%{}, %{"reviewer" => 1}))

      assert {:follow, %{id: "e4"}} =
               Graph.route(graph, "reviewer", :clean, counts(%{}, %{"reviewer" => 2}))
    end

    test "triage: the worst severity among the findings, else clean" do
      assert Graph.triage([]) == :clean
      assert Graph.triage([%{severity: :low}, %{severity: :medium}]) == :medium
      assert Graph.triage([%{severity: :low}, %{severity: :high}]) == :high
      assert Graph.triage([%{severity: :low}]) == :low
    end

    test "a triage block inside a group: severities it has no arrow for leave the group" do
      params = %{
        nodes: [
          group("g", %{"start" => true}),
          agent("r", "reviewer", %{"group_id" => "g"}),
          %{"id" => "t", "kind" => "triage", "label" => "Triage", "group_id" => "g", "x" => 1},
          agent("c", "coder", %{"x" => 2}),
          column("d", "done")
        ],
        edges: [
          arrow("e1", "r", "t"),
          arrow("serious", "t", "c", "high"),
          arrow("back", "c", "g", "done", 3),
          arrow("out", "g", "d", "low")
        ]
      }

      {:ok, graph} = Graph.validate(params, @employees)
      assert {:follow, %{id: "serious"}} = Graph.route(graph, "t", :high, counts())
      assert {:follow, %{id: "out"}} = Graph.route(graph, "t", :low, counts())
      assert Graph.route(graph, "t", :clean, counts()) == :none
    end

    test "nothing fits: :none", %{graph: graph} do
      assert Graph.route(graph, "approve_plan", :whatever, counts()) == :none
      assert Graph.route(graph, "done", nil, counts()) == :none
    end

    test "a group is entered at its first block and left by its own arrows" do
      params = %{
        nodes: [
          agent("start", "planner", %{"start" => true}),
          group("g", %{"x" => 1}),
          agent("coder", "coder", %{"group_id" => "g", "x" => 2}),
          agent("reviewer", "reviewer", %{"group_id" => "g", "x" => 3}),
          human("approve", %{"x" => 4}),
          column("done", "done")
        ],
        edges: [
          arrow("in", "start", "g", "plan_ready"),
          arrow("inner", "coder", "reviewer", "done"),
          arrow("out", "g", "approve", "clean"),
          arrow("yes", "approve", "done", "accepted"),
          arrow("no", "approve", "g", "not accepted")
        ]
      }

      assert {:ok, graph} = Graph.validate(params, @employees)
      assert {%{id: "coder"}, [%{id: "g"}]} = Graph.resolve(graph, "g")
      assert {:follow, %{id: "out"}} = Graph.route(graph, "reviewer", :clean, counts())
      assert Graph.route(graph, "reviewer", :findings, counts()) == :none
      assert Enum.map(Graph.order(graph), & &1.id) == ~w(start g coder reviewer approve done)
    end

    test "a review loop inside a group: outcomes the reviewer has no arrow for leave the group" do
      {:ok, graph} = Graph.validate(review_loop_group(), @employees)

      assert {:follow, %{id: "back"}} = Graph.route(graph, "reviewer", :findings, counts())
      assert {:follow, %{id: "out"}} = Graph.route(graph, "reviewer", :clean, counts())

      # The fix rounds used up: the findings fall out to the one arrow the group has left.
      assert {:follow, %{id: "out"}} =
               Graph.route(graph, "reviewer", :findings, counts(%{"back" => 3}))

      # A coder ending blocked still pauses: no arrow inside or out of the group names it.
      assert Graph.route(graph, "coder", :blocked, counts()) == :pause
    end

    test "a pausing outcome the group's arrows name leaves the group, never by an unnamed arrow" do
      params =
        update_in(review_loop_group().edges, fn edges ->
          Enum.map(edges, &if(&1["id"] == "inner", do: %{&1 | "condition" => nil}, else: &1)) ++
            [arrow("stuck", "g", "approve", "blocked")]
        end)

      {:ok, graph} = Graph.validate(params, @employees)
      assert {:follow, %{id: "stuck"}} = Graph.route(graph, "coder", :blocked, counts())
    end
  end
end
