defmodule Weworkai.Diff.Line do
  @moduledoc """
  One line of a hunk. `old` / `new` are its numbers in the old and new file; an addition
  has no old number, a deletion no new one, a note ("No newline at end of file") neither.
  """
  @enforce_keys [:kind, :old, :new, :text]
  defstruct [:kind, :old, :new, :text]

  @type kind :: :addition | :deletion | :context | :note
  @type t :: %__MODULE__{
          kind: kind,
          old: pos_integer | nil,
          new: pos_integer | nil,
          text: String.t()
        }

  @spec new(kind, pos_integer | nil, pos_integer | nil, String.t()) :: t()
  def new(kind, old, new, text), do: %__MODULE__{kind: kind, old: old, new: new, text: text}
end
