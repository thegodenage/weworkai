defmodule Weworkai.Scheduling do
  use Ash.Domain, otp_app: :weworkai

  resources do
    resource Weworkai.Scheduling.Job do
      define :create_job, action: :create
      define :get_job, action: :read, get_by: [:id]
      define :task_jobs, action: :for_task, args: [:task_id]
      define :active_jobs, action: :active, args: [:task_id]
      define :active_asks, action: :active_asks, args: [:task_id]
      define :latest_job, action: :latest, args: [:task_id], not_found_error?: false
      define :agent_active_jobs, action: :active_for_agent, args: [:agent_id]
      define :start_job, action: :start
      define :run_job, action: :run
      define :complete_job, action: :complete
      define :fail_job, action: :fail
      define :cancel_job, action: :cancel
      define :hold_job, action: :hold
      define :resume_job, action: :resume
      define :requeue_job, action: :requeue
    end

    resource Weworkai.Scheduling.ScheduledJob do
      define :schedule_job, action: :create
      define :due_scheduled_jobs, action: :due
      define :started_scheduled_jobs, action: :started
      define :task_runs, action: :runs_for_task, args: [:task_id]
      define :mark_started, action: :mark_started, args: [:agent_run_id]
      define :mark_completed, action: :mark_completed
      define :mark_failed, action: :mark_failed, args: [:error]
      define :mark_rejected, action: :mark_rejected, args: [:error]
      define :mark_run_failed, action: :mark_run_failed, args: [:error]
      define :mark_timed_out, action: :mark_timed_out, args: [:error]
      define :mark_canceled, action: :mark_canceled
    end
  end
end
