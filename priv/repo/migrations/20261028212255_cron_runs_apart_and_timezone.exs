defmodule Weworkai.Repo.Migrations.CronRunsApartAndTimezone do
  @moduledoc """
  A cron task keeps its cron's time zone (its slot reads the same once the cron is gone),
  and remembers when a person took it out of its group (`apart`), so its cron doesn't
  group it again. Cron tasks already made take their cron's zone.

  Generated with `mix ash_postgres.generate_migrations`; the backfill added by hand.
  """

  use Ecto.Migration

  def up do
    alter table(:tasks) do
      add :cron_timezone, :text
      add :apart, :boolean, null: false, default: false
    end

    execute("""
    UPDATE tasks SET cron_timezone = crons.timezone
    FROM crons WHERE tasks.cron_id = crons.id
    """)
  end

  def down do
    alter table(:tasks) do
      remove :apart
      remove :cron_timezone
    end
  end
end
