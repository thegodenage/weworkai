defmodule Weworkai.DiffTest do
  use ExUnit.Case, async: true

  alias Weworkai.Diff
  alias Weworkai.Diff.{Hunk, Line}

  defp lines(diff),
    do:
      Enum.map(diff.hunks, fn hunk ->
        Enum.map(hunk.lines, &{&1.kind, &1.old, &1.new, &1.text})
      end)

  test "numbers context, additions and deletions from the hunk header" do
    diff =
      Diff.parse("""
      diff --git a/lib/x.ex b/lib/x.ex
      index 123..456 100644
      --- a/lib/x.ex
      +++ b/lib/x.ex
      @@ -10,4 +10,5 @@ defmodule X do
         def a, do: 1
      -  def b, do: 2
      +  def b, do: 3
      +  def c, do: 4
         def d, do: 5
      """)

    assert [%Hunk{header: "@@ -10,4 +10,5 @@ defmodule X do"}] = diff.hunks

    assert lines(diff) == [
             [
               {:context, 10, 10, "  def a, do: 1"},
               {:deletion, 11, nil, "  def b, do: 2"},
               {:addition, nil, 11, "  def b, do: 3"},
               {:addition, nil, 12, "  def c, do: 4"},
               {:context, 12, 13, "  def d, do: 5"}
             ]
           ]

    assert diff.additions == 2
    assert diff.deletions == 1
  end

  test "a new file starts at line 1" do
    diff = Diff.parse("--- /dev/null\n+++ b/lib/greeting.ex\n@@ -0,0 +1,2 @@\n+one\n+two\n")

    assert lines(diff) == [[{:addition, nil, 1, "one"}, {:addition, nil, 2, "two"}]]
  end

  test "several hunks keep their own numbering" do
    diff = Diff.parse("@@ -1 +1 @@\n-a\n+b\n@@ -20,2 +20,2 @@\n c\n-d\n+e\n")

    assert [[{:deletion, 1, nil, "a"}, {:addition, nil, 1, "b"}], second] = lines(diff)

    assert second == [
             {:context, 20, 20, "c"},
             {:deletion, 21, nil, "d"},
             {:addition, nil, 21, "e"}
           ]
  end

  test "lines without a hunk header are numbered from 1" do
    diff = Diff.parse("+defmodule A do\n+end")

    assert [%Hunk{header: nil}] = diff.hunks
    assert lines(diff) == [[{:addition, nil, 1, "defmodule A do"}, {:addition, nil, 2, "end"}]]
  end

  test "keeps blank context lines and the no-newline note" do
    diff = Diff.parse("@@ -1,2 +1,2 @@\n a\n\n-b\n\\ No newline at end of file\n")

    assert lines(diff) == [
             [
               {:context, 1, 1, "a"},
               {:context, 2, 2, ""},
               {:deletion, 3, nil, "b"},
               {:note, nil, nil, "No newline at end of file"}
             ]
           ]
  end

  test "a hunk's own lines that look like file headers stay lines" do
    diff =
      Diff.parse("""
      --- a/priv/schema.sql
      +++ b/priv/schema.sql
      @@ -1,3 +1,3 @@
       select 1;
      --- users are soft deleted
      +++ counter
       select 2;
      --- a/next.sql
      +++ b/next.sql
      """)

    assert lines(diff) == [
             [
               {:context, 1, 1, "select 1;"},
               {:deletion, 2, nil, "-- users are soft deleted"},
               {:addition, nil, 2, "++ counter"},
               {:context, 3, 3, "select 2;"}
             ]
           ]
  end

  test "an empty diff has no hunks" do
    assert %Diff{hunks: [], additions: 0, deletions: 0} = Diff.parse("")
  end

  test "a reference points at the new line, or the old one for a deletion" do
    assert Diff.line_number(Line.new(:addition, nil, 4, "")) == 4
    assert Diff.line_number(Line.new(:context, 3, 5, "")) == 5
    assert Diff.line_number(Line.new(:deletion, 7, nil, "")) == 7
  end

  describe "files" do
    test "splits a branch's diff per file, a deleted file by its old path" do
      branch = """
      diff --git a/lib/greeting.ex b/lib/greeting.ex
      index 1111111..2222222 100644
      --- a/lib/greeting.ex
      +++ b/lib/greeting.ex
      @@ -1,2 +1,3 @@
       defmodule Greeting do
      -  def hello, do: "Hi"
      +  def hello(name), do: "Hello, name!"
      +  def bye, do: "Bye"
      diff --git a/lib/old.ex b/lib/old.ex
      deleted file mode 100644
      --- a/lib/old.ex
      +++ /dev/null
      @@ -1 +0,0 @@
      -defmodule Old, do: nil
      """

      assert [{"lib/greeting.ex", greeting}, {"lib/old.ex", old}] = Diff.files(branch)
      assert {greeting.additions, greeting.deletions} == {2, 1}
      assert {old.additions, old.deletions} == {0, 1}
    end

    test "a single file's diff without a git header is one file" do
      assert [{"lib/greeting.ex", %Diff{additions: 1}}] =
               Diff.files("--- /dev/null\n+++ b/lib/greeting.ex\n@@ -0,0 +1 @@\n+x\n")
    end

    test "an empty diff has no files" do
      assert Diff.files("") == []
    end
  end
end
