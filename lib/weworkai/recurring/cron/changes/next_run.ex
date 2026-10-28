defmodule Weworkai.Recurring.Cron.Changes.NextRun do
  @moduledoc """
  The cron's next slot after now, from its mode's fields and time zone; nil while it is
  paused. Runs once the changeset is valid, so the zone and expression are good ones.
  """
  use Ash.Resource.Change

  alias Weworkai.Recurring.Runner

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      schedule =
        Map.new(
          [:mode, :days, :at, :expression, :timezone],
          &{&1, Ash.Changeset.get_attribute(changeset, &1)}
        )

      next =
        if Ash.Changeset.get_attribute(changeset, :enabled),
          do: Runner.next_run(schedule, DateTime.utc_now())

      Ash.Changeset.force_change_attribute(changeset, :next_run_at, next)
    end)
  end
end
