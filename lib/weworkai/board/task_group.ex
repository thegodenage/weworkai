defmodule Weworkai.Board.TaskGroup do
  @moduledoc """
  Tasks shown together as one stack per column on the board (docs/recurring.md, "Groups"):
  a cron's runs close together (`cron_id` set, by `Recurring.Runner`), or any tasks a
  person groups from the drawer. A group goes when its last task leaves it
  (`Task.Changes.DropEmptyGroup`).
  """
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Board,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "task_groups"
    repo Weworkai.Repo

    references do
      reference :cron, on_delete: :nilify
    end
  end

  actions do
    defaults [:read, :destroy]

    read :list do
      prepare build(sort: [name: :asc, inserted_at: :asc])
    end

    create :create do
      primary? true
      accept [:name]
    end

    # A cron's own: its runs close together (Recurring.Runner).
    create :create_for_cron do
      accept [:name, :cron_id]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 200
    end

    timestamps()
  end

  relationships do
    belongs_to :cron, Weworkai.Recurring.Cron, public?: true
    has_many :tasks, Weworkai.Board.Task, destination_attribute: :group_id
  end

  aggregates do
    count :task_count, :tasks
  end
end
