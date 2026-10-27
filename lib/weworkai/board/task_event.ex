defmodule Weworkai.Board.TaskEvent do
  @moduledoc """
  A step on a task, for its audit timeline (`Weworkai.Audit.Timeline`): a move on
  the board, a plan approved or commented on, questions answered, a decision, a Continue;
  or the scheduler stopping a run that stalled or timed out. Agent work is read from the
  task's jobs; these are the points between it.
  """
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Board,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "task_events"
    repo Weworkai.Repo

    references do
      reference :task, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:task_id, :kind, :label, :node_id]
    end

    read :for_task do
      argument :task_id, :uuid, allow_nil?: false
      filter expr(task_id == ^arg(:task_id))
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, Weworkai.Board.TaskEvent.Kind, allow_nil?: false, public?: true

    attribute :label, :string do
      allow_nil? false
      public? true
      constraints max_length: 500
    end

    # The block the task was on; no foreign key, blocks are replaced when their graph is saved.
    attribute :node_id, :uuid, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :task, Weworkai.Board.Task, allow_nil?: false, public?: true
  end
end
