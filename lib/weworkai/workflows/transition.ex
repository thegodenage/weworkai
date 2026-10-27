defmodule Weworkai.Workflows.Transition do
  @moduledoc """
  What the engine does in answer to a run or a human: the task's new attributes, plus the
  messages, notifications, jobs and human-step events (the audit timeline's points) to
  create. Built outside any transaction (it may ask the bridge for a diff), then applied in one.
  """
  defstruct task: %{}, messages: [], notifications: [], jobs: [], events: []

  def merge(first, second) do
    %__MODULE__{
      task: Map.merge(first.task, second.task),
      messages: first.messages ++ second.messages,
      notifications: first.notifications ++ second.notifications,
      jobs: first.jobs ++ second.jobs,
      events: first.events ++ second.events
    }
  end
end
