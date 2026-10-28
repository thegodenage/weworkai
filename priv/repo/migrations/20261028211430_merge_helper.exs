defmodule Weworkai.Repo.Migrations.MergeHelper do
  @moduledoc """
  The merge helper: the branch a merger block merges into (nil: the one checked out in the
  repository), and the task's last merge (target branch and merge commit).

  Generated with `mix ash.codegen merge_helper`.
  """

  use Ecto.Migration

  def up do
    alter table(:tasks) do
      add :merged_into, :text
      add :merge_commit, :text
    end

    alter table(:workflow_nodes) do
      add :merge_branch, :text
    end
  end

  def down do
    alter table(:workflow_nodes) do
      remove :merge_branch
    end

    alter table(:tasks) do
      remove :merge_commit
      remove :merged_into
    end
  end
end
