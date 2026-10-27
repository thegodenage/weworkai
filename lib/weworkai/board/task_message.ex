defmodule Weworkai.Board.TaskMessage do
  @moduledoc "One entry of a task's conversation between humans and its agents."
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Board,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "task_messages"
    repo Weworkai.Repo

    references do
      reference :task, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:task_id, :author, :agent_role, :kind, :body, :step_ids]
    end

    # A human's question about the task; an agent answers it with a `reply` message.
    create :ask do
      accept [:task_id, :body]
      validate match(:body, ~r/\S/), message: "must not be blank"
      validate string_length(:body, max: 10_000)
      change set_attribute(:author, :human)
      change set_attribute(:kind, :question)
      change Weworkai.Board.TaskMessage.Changes.Ask
    end

    read :for_task do
      argument :task_id, :uuid, allow_nil?: false
      filter expr(task_id == ^arg(:task_id))
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :author, Weworkai.Board.TaskMessage.Author, allow_nil?: false, public?: true
    # Set when an agent wrote the message.
    attribute :agent_role, Weworkai.Agents.Agent.Role, public?: true
    attribute :kind, Weworkai.Board.TaskMessage.Kind, allow_nil?: false, public?: true

    attribute :body, :string do
      allow_nil? false
      public? true
      constraints max_length: 100_000, trim?: false
    end

    attribute :step_ids, {:array, :string}, allow_nil?: false, public?: true, default: []

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :task, Weworkai.Board.Task, allow_nil?: false, public?: true
  end
end
