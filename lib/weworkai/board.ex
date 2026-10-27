defmodule Weworkai.Board do
  use Ash.Domain, otp_app: :weworkai, extensions: [AshPhoenix]

  @card_fields [
    :assignee,
    :activity,
    :current_node,
    :open_blocker_titles,
    :dependent_ids,
    :child_count,
    :done_child_count
  ]

  @doc "Where `continue_task/2` can take the task, default first (`Engine.continue_targets/1`)."
  defdelegate continue_targets(task), to: Weworkai.Workflows.Engine

  resources do
    resource Weworkai.Board.Task do
      # Moving a task touches updated_at, so a moved card lands at the bottom of its new column.
      define :list_tasks,
        action: :read,
        default_options: [
          query: [sort: [updated_at: :asc]],
          load: @card_fields
        ]

      define :get_task,
        action: :read,
        get_by: [:id],
        default_options: [load: @card_fields]

      define :list_task_choices,
        action: :read,
        default_options: [query: [sort: [inserted_at: :desc], select: [:id, :title, :status]]]

      define :create_subtask, action: :create_subtask, args: [:parent_id, :title]

      define :search_tasks, action: :search, args: [:pattern]
      define :create_task, action: :create
      define :move_task, action: :move, args: [:status]
      define :update_task, action: :update
      define :destroy_task, action: :destroy
      define :advance_task, action: :advance
      define :comment_on_plan, action: :comment_on_plan, args: [:body, {:optional, :step_ids}]
      define :answer_questions, action: :answer_questions, args: [:answers]
      define :approve_plan, action: :approve_plan, args: [{:optional, :coder_employee_id}]
      define :decide_task, action: :decide, args: [:edge_id, {:optional, :comment}]
      define :continue_task, action: :continue, args: [{:optional, :target}]
      define :set_task_budget, action: :set_budget, args: [:budget_usd]
      define :upgrade_task_workflow, action: :upgrade_workflow
    end

    resource Weworkai.Board.TaskDependency do
      define :add_blocker, action: :create, args: [:blocked_id, :blocker_id]
      define :remove_blocker, action: :destroy
      define :get_dependency, action: :read, get_by: [:blocked_id, :blocker_id]
    end

    resource Weworkai.Board.TaskMessage do
      define :create_message, action: :create
      define :list_messages, action: :for_task, args: [:task_id]
      define :ask_question, action: :ask, args: [:task_id, :body]
    end

    resource Weworkai.Board.TaskEvent do
      define :record_event, action: :create
      define :list_events, action: :for_task, args: [:task_id]
    end

    resource Weworkai.Board.TaskAttachment do
      define :attach_file, action: :create
      define :list_attachments, action: :for_task, args: [:task_id]
      define :attachment_files, action: :files_for_task, args: [:task_id]
      define :get_attachment_file, action: :file, get_by: [:id]
      define :remove_attachment, action: :destroy
    end
  end
end
