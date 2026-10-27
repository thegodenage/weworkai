defmodule Weworkai.Board.TaskDependency do
  @moduledoc """
  "`blocked` is blocked by `blocker`". While any blocker of a task is neither done nor
  canceled the scheduler starts none of its agents (`ScheduledJob` `:due`); its queued work
  starts on the tick after its last blocker closes (`Task.Changes.ReleaseDependents`).
  A link that would close a loop is refused, so waiting always ends.
  """
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Board,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub]

  alias Weworkai.Board.TaskDependency.Validations.Acyclic

  postgres do
    table "task_dependencies"
    repo Weworkai.Repo

    references do
      reference :blocked, on_delete: :delete
      reference :blocker, on_delete: :delete
    end

    custom_indexes do
      index [:blocker_id]
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:blocked_id, :blocker_id]
      validate Acyclic
    end
  end

  # The blocked task's card and page show the link.
  pub_sub do
    module Phoenix.PubSub
    name Weworkai.PubSub
    transform fn notification -> {:task_updated, %{id: notification.data.blocked_id}} end
    publish_all :create, "tasks"
    publish_all :destroy, "tasks"
  end

  attributes do
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :blocked, Weworkai.Board.Task,
      primary_key?: true,
      allow_nil?: false,
      public?: true

    belongs_to :blocker, Weworkai.Board.Task,
      primary_key?: true,
      allow_nil?: false,
      public?: true
  end
end
