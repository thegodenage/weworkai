defmodule Weworkai.Diff do
  @moduledoc """
  Parses a unified diff (one file's, as a planner writes it per change) into hunks of
  numbered lines, for rendering like a merge request. File headers (`---`, `+++`,
  `diff --git`, `index`) are dropped, except inside a hunk whose header counts more lines
  (a deleted `-- comment` reads `--- comment`). Lines before the first `@@` header form a
  hunk without a header, numbered from 1, since planners sometimes leave the header out.
  """
  alias Weworkai.Diff.{Hunk, Line}

  @enforce_keys [:hunks, :additions, :deletions]
  defstruct [:hunks, :additions, :deletions]

  @type t :: %__MODULE__{
          hunks: [Hunk.t()],
          additions: non_neg_integer,
          deletions: non_neg_integer
        }

  @hunk_header ~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$/
  @file_header ~r/^(--- |\+\+\+ |diff --git |index |new file mode |deleted file mode )/

  @spec parse(String.t()) :: t()
  def parse(text) do
    hunks =
      text
      |> String.split(["\r\n", "\n"])
      |> drop_trailing_blank()
      |> Enum.reduce([], &read/2)
      |> Enum.map(&Hunk.finish/1)
      |> Enum.reverse()

    lines = Enum.flat_map(hunks, & &1.lines)

    %__MODULE__{
      hunks: hunks,
      additions: Enum.count(lines, &(&1.kind == :addition)),
      deletions: Enum.count(lines, &(&1.kind == :deletion))
    }
  end

  @file_start ~r/^(?=diff --git )/m
  @new_path ~r/^\+\+\+ b\/(.+)$/m
  @old_path ~r/^--- a\/(.+)$/m
  @git_path ~r/^diff --git a\/.+ b\/(.+)$/m

  @doc """
  Splits a whole branch's diff (`git diff`, files led by `diff --git`) into each file's,
  as `{path, parsed}`. The path is the new one, or the old one for a deleted file.
  """
  @spec files(String.t()) :: [{String.t(), t()}]
  def files(text) do
    text
    |> String.split(@file_start, trim: true)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(&{path(&1), parse(&1)})
  end

  defp path(file) do
    Enum.find_value([@new_path, @old_path, @git_path], "(unnamed)", fn pattern ->
      with [_line, path] <- Regex.run(pattern, file), do: path
    end)
  end

  defp drop_trailing_blank(lines) do
    case List.last(lines) do
      "" -> List.delete_at(lines, -1)
      _line -> lines
    end
  end

  defp read(raw, hunks) do
    case {Regex.run(@hunk_header, raw), hunks} do
      {[header, old, old_count, new, new_count, _section], _hunks} ->
        [
          Hunk.new(header, {number(old), count(old_count)}, {number(new), count(new_count)})
          | hunks
        ]

      {nil, [current | rest]} ->
        if Regex.match?(@file_header, raw) and not Hunk.open?(current),
          do: hunks,
          else: [Hunk.add(current, raw) | rest]

      {nil, []} ->
        if Regex.match?(@file_header, raw),
          do: hunks,
          else: [Hunk.add(Hunk.new(nil, {1, 0}, {1, 0}), raw)]
    end
  end

  defp number(digits), do: String.to_integer(digits)

  # "@@ -3 +3 @@" omits a count of 1.
  defp count(""), do: 1
  defp count(digits), do: String.to_integer(digits)

  @doc "The line a reference to `line` points at: its new number, or the old one for a deletion."
  @spec line_number(Line.t()) :: pos_integer
  def line_number(%Line{new: nil, old: old}), do: old
  def line_number(%Line{new: new}), do: new
end
