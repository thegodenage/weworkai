defmodule Weworkai.Fuzzy do
  @moduledoc """
  Fuzzy matching for the command palette: a query matches a text when its characters
  appear in it in order, case-insensitively ("nwtsk" matches "New task"); a run of spaces
  in the query matches one space.

  `pattern/1` is the same test as an `ilike` pattern, so a search action narrows its rows
  in the database; `match/2` then ranks them and finds the characters to highlight.
  """

  @enforce_keys [:characters]
  defstruct [:characters]

  @type t :: %__MODULE__{characters: [String.t(), ...]}
  @type match :: %{score: integer(), positions: [non_neg_integer()]}

  @max_length 64

  @doc "The query, or `:error` when it has nothing to match (blank)."
  @spec new(String.t()) :: {:ok, t()} | :error
  def new(query) do
    case query
         |> String.slice(0, @max_length)
         |> String.trim()
         |> String.replace(~r/\s+/u, " ") do
      "" -> :error
      normalized -> {:ok, %__MODULE__{characters: lowercase(normalized)}}
    end
  end

  @doc "An `ilike` pattern matching the texts `match/2` matches: `%n%w%t%`."
  @spec pattern(t()) :: String.t()
  def pattern(%__MODULE__{characters: characters}),
    do: "%" <> Enum.map_join(characters, "%", &escape/1) <> "%"

  @doc """
  Where the query's characters are in `text` (grapheme indexes), and a score to rank by:
  a run of them at a word's start beats a run anywhere, which beats scattered characters;
  earlier and tighter beat later and looser. Nil when the text doesn't match.
  """
  @spec match(t(), String.t()) :: match() | nil
  def match(%__MODULE__{characters: characters}, text) do
    graphemes = lowercase(text)

    case runs(graphemes, characters) do
      [] -> scattered(graphemes, characters)
      starts -> run_match(graphemes, starts, length(characters))
    end
  end

  defp run_match(graphemes, starts, length) do
    case Enum.find(starts, &word_start?(graphemes, &1)) do
      nil -> run(hd(starts), length, 2000)
      start -> run(start, length, 3000)
    end
  end

  defp run(start, length, base),
    do: %{score: base - start, positions: Enum.to_list(start..(start + length - 1)//1)}

  defp runs(graphemes, characters) do
    length = length(characters)

    for start <- 0..(length(graphemes) - length)//1,
        Enum.slice(graphemes, start, length) == characters,
        do: start
  end

  defp scattered(graphemes, characters) do
    graphemes
    |> Enum.with_index()
    |> Enum.reduce_while({characters, []}, fn
      {grapheme, index}, {[grapheme | rest], positions} ->
        if rest == [],
          do: {:halt, {[], [index | positions]}},
          else: {:cont, {rest, [index | positions]}}

      _other, state ->
        {:cont, state}
    end)
    |> case do
      {[], [last | _] = positions} ->
        first = List.last(positions)
        %{score: 1000 - (last - first), positions: Enum.reverse(positions)}

      _unmatched ->
        nil
    end
  end

  defp word_start?(_graphemes, 0), do: true

  defp word_start?(graphemes, index),
    do: not String.match?(Enum.at(graphemes, index - 1), ~r/^[[:alnum:]]$/u)

  defp lowercase(text), do: text |> String.graphemes() |> Enum.map(&String.downcase/1)

  defp escape(character) when character in ["%", "_", "\\"], do: "\\" <> character
  defp escape(character), do: character
end
