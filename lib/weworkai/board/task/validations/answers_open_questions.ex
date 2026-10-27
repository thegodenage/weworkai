defmodule Weworkai.Board.Task.Validations.AnswersOpenQuestions do
  @moduledoc "Answers come for exactly the open questions: each one answered, no unknown ids."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    question_ids = MapSet.new(changeset.data.open_questions, & &1.id)
    answers = Ash.Changeset.get_argument(changeset, :answers)

    cond do
      MapSet.size(question_ids) == 0 ->
        {:error, field: :answers, message: "there are no open questions"}

      MapSet.new(Map.keys(answers)) != question_ids ->
        {:error, field: :answers, message: "must answer exactly the open questions"}

      Enum.any?(Map.values(answers), &blank?/1) ->
        {:error, field: :answers, message: "must not be blank"}

      true ->
        :ok
    end
  end

  defp blank?(answer), do: not is_binary(answer) or String.trim(answer) == ""
end
