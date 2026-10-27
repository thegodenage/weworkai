defmodule Weworkai.Board.TaskAttachmentTest do
  use Weworkai.DataCase, async: true

  alias Weworkai.Board

  test "a task's files stay within its limit; replacing a file does not count twice" do
    task = Board.create_task!(%{title: "Big files"})
    big = :binary.copy(<<0>>, 60_000_000)

    Board.attach_file!(%{task_id: task.id, file_name: "a.bin", content: big})
    Board.attach_file!(%{task_id: task.id, file_name: "a.bin", content: big})

    assert {:error, %Ash.Error.Invalid{}} =
             Board.attach_file(%{task_id: task.id, file_name: "b.bin", content: big})

    assert [%{name: "a.bin", size: 60_000_000}] = Board.list_attachments!(task.id)
  end

  test "an uploaded name becomes a plain file name" do
    task = Board.create_task!(%{title: "Names"})

    attachment =
      Board.attach_file!(%{task_id: task.id, file_name: "../../.ssh/zrzut ąę.png", content: "x"})

    assert attachment.name == "zrzut __.png"
  end
end
