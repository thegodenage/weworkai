defmodule Weworkai.Recurring do
  @moduledoc """
  Crons (docs/recurring.md): workflows that run on their own. At each of a cron's slots
  (weekdays at a time of day, or the matches of a cron expression, on the clock of a time
  zone) `Weworkai.Recurring.Runner` creates a task on its workflow, tagged CRON, and moves
  it to todo, which starts it.
  """
  use Ash.Domain, otp_app: :weworkai, extensions: [AshPhoenix]

  resources do
    resource Weworkai.Recurring.Cron do
      define :list_crons, action: :list
      define :get_cron, action: :read, get_by: [:id]
      define :create_cron, action: :create
      define :update_cron, action: :update
      define :destroy_cron, action: :destroy
      define :due_crons, action: :due, args: [:now]
      define :claim_cron, action: :claim
      define :record_cron_run, action: :record_run
    end
  end

  @doc "A moment on a cron's own clock: \"Wed 28 Oct, 09:00\"."
  def local_time(nil, _timezone), do: "—"

  def local_time(datetime, timezone) do
    datetime
    |> DateTime.shift_zone!(timezone || "Etc/UTC")
    |> Calendar.strftime("%a %d %b, %H:%M")
  end
end
