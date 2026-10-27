defmodule Weworkai.Agents.Errors.OverBudget do
  @moduledoc """
  A run would spend past a budget (`Weworkai.Agents.Budget`) already spent. Starting it
  again fails the same way until a human raises the cap.
  """
  use Splode.Error, fields: [:budget], class: :invalid

  alias Weworkai.Agents.Budget

  def message(%{budget: budget}),
    do: "Budget reached. #{Budget.describe(budget)} #{Budget.raise_hint(budget)}"
end
