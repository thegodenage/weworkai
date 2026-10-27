defmodule Weworkai.Board.TaskAttachment.Validations.WithinTaskLimit do
  @moduledoc """
  A task's files together stay within what one run carries to the bridge. A file under the
  same name is being replaced, so it does not count.
  """
  use Ash.Resource.Validation

  alias Weworkai.Board
  alias Weworkai.Board.TaskAttachment

  @impl true
  def validate(changeset, _opts, _context) do
    name = Ash.Changeset.get_attribute(changeset, :name)
    size = byte_size(Ash.Changeset.get_attribute(changeset, :content))

    others =
      changeset
      |> Ash.Changeset.get_attribute(:task_id)
      |> Board.list_attachments!()
      |> Enum.reject(&(&1.name == name))
      |> Enum.sum_by(& &1.size)

    if others + size <= TaskAttachment.max_task_bytes(),
      do: :ok,
      else: {:error, field: :content, message: "would take the task's files over its limit"}
  end
end
