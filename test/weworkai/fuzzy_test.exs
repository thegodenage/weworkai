defmodule Weworkai.FuzzyTest do
  use ExUnit.Case, async: true

  alias Weworkai.Fuzzy

  defp fuzzy(query) do
    {:ok, fuzzy} = Fuzzy.new(query)
    fuzzy
  end

  test "a blank query matches nothing" do
    assert Fuzzy.new("") == :error
    assert Fuzzy.new("   ") == :error
  end

  test "the pattern is the query's characters in order, wildcards escaped" do
    assert Fuzzy.pattern(fuzzy(" Nw   T ")) == "%n%w% %t%"
    assert Fuzzy.pattern(fuzzy("5%_\\")) == "%5%\\%%\\_%\\\\%"
  end

  test "characters in order match, case-insensitively, at their positions" do
    assert %{positions: [0, 2, 4]} = Fuzzy.match(fuzzy("nwt"), "New task")
    assert Fuzzy.match(fuzzy("twn"), "New task") == nil
    assert %{positions: [0, 1, 2, 3, 4, 5, 6, 7]} = Fuzzy.match(fuzzy("new  task"), "New task")
  end

  test "a run at a word's start ranks above a run inside a word, above scattered characters" do
    query = fuzzy("task")
    word = Fuzzy.match(query, "New task")
    inside = Fuzzy.match(query, "Multitasking")
    scattered = Fuzzy.match(query, "the a s k")

    assert word.positions == [4, 5, 6, 7]
    assert inside.positions == [5, 6, 7, 8]
    assert word.score > inside.score
    assert inside.score > scattered.score
  end

  test "earlier and tighter matches rank higher" do
    query = fuzzy("ab")
    assert Fuzzy.match(query, "ab x").score > Fuzzy.match(query, "x ab").score
    assert Fuzzy.match(query, "a-b").score > Fuzzy.match(query, "a---b").score
  end
end
