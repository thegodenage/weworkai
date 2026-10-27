defmodule Weworkai.Diff.Hunk do
  @moduledoc """
  One `@@` section of a diff; `header` is nil for lines before any `@@` header.
  `old_end` / `new_end` are the line numbers just past the lines its header announces.
  """
  alias Weworkai.Diff.Line

  @enforce_keys [:header, :lines, :next_old, :next_new, :old_end, :new_end]
  defstruct [:header, :lines, :next_old, :next_new, :old_end, :new_end]

  @type t :: %__MODULE__{
          header: String.t() | nil,
          lines: [Line.t()],
          next_old: pos_integer,
          next_new: pos_integer,
          old_end: pos_integer,
          new_end: pos_integer
        }

  @type range :: {start :: non_neg_integer, count :: non_neg_integer}

  @spec new(String.t() | nil, range, range) :: t()
  def new(header, {old_start, old_count}, {new_start, new_count}) do
    # A hunk starting at 0 adds to (or deletes from) an empty file; its first line is 1.
    %__MODULE__{
      header: header,
      lines: [],
      next_old: max(old_start, 1),
      next_new: max(new_start, 1),
      old_end: max(old_start, 1) + old_count,
      new_end: max(new_start, 1) + new_count
    }
  end

  @doc "Whether the header announces lines this hunk hasn't read yet."
  @spec open?(t()) :: boolean
  def open?(hunk), do: hunk.next_old < hunk.old_end or hunk.next_new < hunk.new_end

  @doc "Appends one raw diff line; lines are kept reversed until `finish/1`."
  @spec add(t(), String.t()) :: t()
  def add(hunk, "+" <> text), do: push(hunk, Line.new(:addition, nil, hunk.next_new, text), 0, 1)
  def add(hunk, "-" <> text), do: push(hunk, Line.new(:deletion, hunk.next_old, nil, text), 1, 0)
  def add(hunk, "\\" <> text), do: push(hunk, Line.new(:note, nil, nil, String.trim(text)), 0, 0)
  def add(hunk, " " <> text), do: context(hunk, text)
  def add(hunk, text), do: context(hunk, text)

  defp context(hunk, text),
    do: push(hunk, Line.new(:context, hunk.next_old, hunk.next_new, text), 1, 1)

  defp push(hunk, line, old_step, new_step) do
    %{
      hunk
      | lines: [line | hunk.lines],
        next_old: hunk.next_old + old_step,
        next_new: hunk.next_new + new_step
    }
  end

  @spec finish(t()) :: t()
  def finish(hunk), do: %{hunk | lines: Enum.reverse(hunk.lines)}
end
