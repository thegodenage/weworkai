defmodule Weworkai.Board.TaskAttachment do
  @moduledoc """
  A file a human attached to a task. Every run on the task finds the task's files in its
  working directory (`Weworkai.Workflows.Engine.attachments/1`), and each stage's first prompt
  lists them.
  """
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Board,
    data_layer: AshPostgres.DataLayer

  alias Weworkai.Board.TaskAttachment.Validations

  @max_file_bytes 25_000_000
  # Every run carries all of the task's files; bin/claude_bridge's MAX_ATTACHMENT_BYTES.
  @max_task_bytes 100_000_000
  # Raster images only: an SVG opened directly can run scripts.
  @images ~w(image/png image/jpeg image/gif image/webp)

  def max_file_bytes, do: @max_file_bytes
  def max_task_bytes, do: @max_task_bytes

  @doc "Whether the app may show the file inline: a thumbnail, or opened in the browser."
  def image?(name), do: MIME.from_path(name) in @images

  @doc "`name` as a file name the bridge accepts: no folders, other characters as `_`."
  def safe_name(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9_ .()-]/u, "_")
    |> String.replace(~r/^[ .()-]+/, "")
    |> String.slice(0, 200)
  end

  postgres do
    table "task_attachments"
    repo Weworkai.Repo

    references do
      reference :task, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    # Attaching a file under a name the task already has replaces that file.
    create :create do
      accept [:task_id, :content]
      # The name on the uploader's computer, whatever it is.
      argument :file_name, :string, allow_nil?: false
      upsert? true
      upsert_identity :unique_name
      upsert_fields [:content]

      change fn changeset, _context ->
        name = __MODULE__.safe_name(Ash.Changeset.get_argument(changeset, :file_name))
        Ash.Changeset.force_change_attribute(changeset, :name, name)
      end

      validate Validations.WithinTaskLimit
    end

    read :for_task do
      argument :task_id, :uuid, allow_nil?: false
      filter expr(task_id == ^arg(:task_id))
      prepare build(sort: [name: :asc], load: [:size])
    end

    # The reads below load the bytes: for a run on the task, and for one download.
    read :files_for_task do
      argument :task_id, :uuid, allow_nil?: false
      filter expr(task_id == ^arg(:task_id))
      prepare build(sort: [name: :asc], select: [:name, :content])
    end

    read :file do
      prepare build(select: [:name, :content])
    end
  end

  attributes do
    uuid_primary_key :id

    # A plain file name: the bridge writes it into the agent's working directory.
    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 200, match: ~r/^[A-Za-z0-9_][A-Za-z0-9_ .()-]*$/
    end

    attribute :content, :binary do
      allow_nil? false
      public? true
      select_by_default? false
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :task, Weworkai.Board.Task, allow_nil?: false, public?: true
  end

  calculations do
    calculate :size, :integer, expr(fragment("octet_length(?)", content))
  end

  identities do
    identity :unique_name, [:task_id, :name]
  end
end
