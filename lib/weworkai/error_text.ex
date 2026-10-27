defmodule Weworkai.ErrorText do
  @moduledoc """
  Error text a person reads: the errors' own messages, without Ash's breadcrumbs and
  stacktraces (those go to the log).
  """

  def readable(error) do
    %{errors: errors} = Ash.Error.to_error_class(error)
    Enum.map_join(errors, " ", &message/1)
  end

  # Splode prefixes an error's own message with its breadcrumbs.
  defp message(error) do
    error |> Map.replace(:bread_crumbs, []) |> Exception.message() |> String.trim()
  end

  @doc """
  Messages and notifications saved before errors were made readable hold Ash's whole dump
  ("Bread Crumbs: … * the error … stacktrace"); this keeps the text before it and the
  error lines. Any other text is returned as is.
  """
  def clean(text) do
    case String.split(text, "Bread Crumbs:", parts: 2) do
      [text] ->
        text

      [prefix, dump] ->
        errors = Regex.scan(~r/^\* (.+)$/m, dump, capture: :all_but_first)
        Enum.join([String.trim(prefix) | List.flatten(errors)], " ")
    end
  end
end
