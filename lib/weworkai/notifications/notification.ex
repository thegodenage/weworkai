defmodule Weworkai.Notifications.Notification do
  @moduledoc """
  Something a person should know about: every status change the workflow makes and every
  agent failure. Each new one is broadcast on the "notifications" topic as
  `{:notification_created, notification}`.
  """
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Notifications,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub]

  require Ash.Query

  postgres do
    table "notifications"
    repo Weworkai.Repo

    references do
      reference :task, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:task_id, :kind, :title, :body]
    end

    read :recent do
      argument :limit, :integer, default: 20, constraints: [min: 1, max: 100]
      argument :unread, :boolean, default: false
      filter expr(not (^arg(:unread)) or is_nil(read_at))
      prepare build(sort: [inserted_at: :desc, id: :desc])
      prepare fn query, _context -> Ash.Query.limit(query, query.arguments.limit) end
    end

    update :mark_read do
      change atomic_update(:read_at, expr(now()))
    end

    action :unread_count, :integer do
      run fn _input, _context ->
        __MODULE__ |> Ash.Query.filter(is_nil(read_at)) |> Ash.count()
      end
    end

    action :mark_all_read do
      run fn _input, _context ->
        __MODULE__
        |> Ash.Query.filter(is_nil(read_at))
        |> Ash.bulk_update!(:mark_read, %{}, strategy: [:atomic])

        :ok
      end
    end
  end

  pub_sub do
    module Phoenix.PubSub
    name Weworkai.PubSub
    transform fn notification -> {:notification_created, notification.data} end
    publish :create, "notifications"
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, Weworkai.Notifications.Notification.Kind, allow_nil?: false, public?: true

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints max_length: 300
    end

    attribute :body, :string, public?: true, constraints: [max_length: 10_000, trim?: false]
    attribute :read_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    # Notifications about the task go with it.
    belongs_to :task, Weworkai.Board.Task, public?: true
  end
end
