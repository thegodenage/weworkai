defmodule Weworkai.Board.Task do
  use Ash.Resource,
    otp_app: :weworkai,
    domain: Weworkai.Board,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub]

  alias Weworkai.Board.Task.{Activity, Calculations, Changes, Validations}
  alias Weworkai.Board.{Finding, Plan, Question}
  alias Weworkai.Scheduling
  alias Weworkai.Workflows.Node

  # The bridge's default allowed folder (CLAUDE_BRIDGE_ROOTS), so a blank repository runs.
  @default_repository "~/Projects"

  def default_repository, do: @default_repository

  postgres do
    table "tasks"
    repo Weworkai.Repo

    references do
      reference :assignee, on_delete: :nilify
      reference :parent, on_delete: :nilify
    end

    custom_indexes do
      index [:parent_id]
    end
  end

  actions do
    defaults [:read]

    # The command palette's candidates: `pattern` is a `Weworkai.Fuzzy.pattern/1`.
    read :search do
      argument :pattern, :string, allow_nil?: false
      filter expr(ilike(title, ^arg(:pattern)))
      prepare build(sort: [updated_at: :desc], limit: 20)
    end

    # Jobs are deleted with the task; canceling them first stops a running agent session.
    destroy :destroy do
      primary? true
      require_atomic? false

      change before_action(fn changeset, _context ->
               task_id = changeset.data.id

               Enum.each(
                 Scheduling.active_jobs!(task_id) ++ Scheduling.active_asks!(task_id),
                 &Scheduling.cancel_job!/1
               )

               changeset
             end)
    end

    create :create do
      accept [:title, :description, :repository, :workflow_id]
      change Changes.DefaultRepository
      change Changes.DefaultWorkflow
      change load(:assignee)
    end

    # Born under its parent: no task is a sub-task of its own sub-task.
    create :create_subtask do
      accept [:title]
      argument :parent_id, :uuid, allow_nil?: false
      change set_attribute(:parent_id, arg(:parent_id))
      change Changes.InheritParent
      change Changes.DefaultWorkflow
    end

    update :update do
      accept [:title, :description, :repository, :workflow_id]
      require_atomic? false
      change Changes.DefaultRepository
      change Changes.SwitchWorkflow
      change load(:assignee)
    end

    # Moving to todo runs the workflow from its current block (or its start), moving into
    # review runs it from its first reviewer block; done and canceled end it.
    update :move do
      accept [:status]
      require_atomic? false

      validate Validations.Reviewable,
        where: [changing(:status), attribute_equals(:status, :review)]

      change Changes.CancelJobs

      change {Changes.Transition, step: :start},
        where: [changing(:status), attribute_equals(:status, :todo)]

      change {Changes.Transition, step: :review},
        where: [changing(:status), attribute_equals(:status, :review)]

      change set_attribute(:current_node_id, nil),
        where: [changing(:status), attribute_in(:status, [:done, :canceled])]

      change Changes.RecordMove
      change load(:assignee)
    end

    # The engine's own writes (Weworkai.Workflows.Engine); not for the UI.
    update :advance do
      accept [
        :status,
        :stage,
        :plan,
        :plan_session_id,
        :plan_session_connector_id,
        :code_session_id,
        :code_session_connector_id,
        :open_questions,
        :findings,
        :outcome_summary,
        :review_round,
        :assignee_id,
        :worktree_path,
        :worktree_branch,
        :current_node_id,
        :workflow_version,
        :edge_counts,
        :node_counts
      ]

      require_atomic? false
      change load(:assignee)
    end

    # Pins the task to its workflow's latest version, on the block it is on
    # (`Workflows.upgrade/1`); an agent working on that block carries on.
    update :upgrade_workflow do
      require_atomic? false
      change Changes.UpgradeWorkflow
      change load(:assignee)
    end

    # The human actions validate the page's copy of the task and filter on the same state,
    # so a second tab (or a double submit) acting on a copy that is no longer current is
    # refused by the database instead of resuming the agent twice.
    update :comment_on_plan do
      argument :body, :string, allow_nil?: false, constraints: [max_length: 10_000]
      argument :step_ids, {:array, :string}, allow_nil?: false, default: []
      require_atomic? false

      validate attribute_equals(:stage, :planning)
      validate attribute_equals(:status, :await_human_supervision)
      validate present(:plan)
      change filter(expr(stage == :planning and status == :await_human_supervision))
      change {Changes.Transition, step: :comment}
      change load(:assignee)
    end

    update :answer_questions do
      # Question id => the human's answer.
      argument :answers, :map, allow_nil?: false
      require_atomic? false

      validate attribute_in(:stage, [:planning, :coding])
      validate attribute_equals(:status, :await_human_supervision)
      validate Validations.AnswersOpenQuestions
      # Agents reuse question ids, so the questions themselves must still be the open ones.
      change fn changeset, _context ->
        questions = changeset.data.open_questions

        Ash.Changeset.filter(
          changeset,
          expr(status == :await_human_supervision and open_questions == ^questions)
        )
      end

      change {Changes.Transition, step: :answer}
      change load(:assignee)
    end

    # Takes the plan's approval arrow to the coder block (Engine.approve/2).
    update :approve_plan do
      # A coder role block with several coders: the one this task's coder blocks then run.
      argument :coder_employee_id, :uuid
      require_atomic? false

      validate attribute_equals(:stage, :planning)
      validate attribute_equals(:status, :await_human_supervision)
      validate present(:plan)
      validate Validations.CoderEmployee, where: present(:coder_employee_id)
      change filter(expr(stage == :planning and status == :await_human_supervision))
      change {Changes.Transition, step: :approve}
      change load(:assignee)
    end

    # A human picks one of the current human block's arrows (Engine.decide/2).
    update :decide do
      argument :edge_id, :uuid, allow_nil?: false
      # Goes with the decision: into its message and the next agent's prompt.
      argument :comment, :string
      require_atomic? false

      validate attribute_equals(:status, :await_human_supervision)
      change Changes.Unchanged
      change {Changes.Transition, step: :decide}
      change load(:assignee)
    end

    update :set_budget do
      accept [:budget_usd]
      require_atomic? false
    end

    # A human pushes the task on from wherever it is stuck: from a block of its workflow
    # (a node id) or to "done" (Engine.continue/2).
    update :continue do
      argument :target, :string
      require_atomic? false

      change Changes.Unchanged
      change {Changes.Transition, step: :continue}
      change load(:assignee)
    end
  end

  # Every change lands on the board live, whether a person or the workflow made it.
  pub_sub do
    module Phoenix.PubSub
    name Weworkai.PubSub

    transform fn
      %{action: %{type: :destroy}, data: task} -> {:task_deleted, task}
      notification -> {:task_updated, notification.data}
    end

    publish_all :update, "tasks"
    publish :create_subtask, "tasks"
    publish :destroy, "tasks"
  end

  changes do
    change Changes.ReleaseDependents,
      on: [:update],
      where: [changing(:status), attribute_in(:status, [:done, :canceled])]
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints max_length: 200
    end

    attribute :description, :string, public?: true

    attribute :status, Weworkai.Board.Task.Status do
      allow_nil? false
      public? true
      default :backlog
    end

    # Folder of the git repository the agents work in.
    attribute :repository, :string do
      allow_nil? false
      public? true
      default @default_repository
      constraints max_length: 1000
    end

    attribute :stage, Weworkai.Board.Task.Stage, public?: true

    attribute :plan, Plan, public?: true
    attribute :plan_approved_at, :utc_datetime_usec, public?: true
    attribute :plan_session_id, :string, public?: true
    attribute :code_session_id, :string, public?: true
    # The connector a conversation ran on: only its own bridge can resume it (nil: unknown,
    # recorded before this was kept).
    attribute :plan_session_connector_id, :uuid, public?: true
    attribute :code_session_connector_id, :uuid, public?: true
    attribute :worktree_path, :string, public?: true
    attribute :worktree_branch, :string, public?: true

    # Fix rounds: times the coder was sent back with the reviewers' findings.
    attribute :review_round, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :open_questions, {:array, Question}, allow_nil?: false, public?: true, default: []
    attribute :findings, {:array, Finding}, allow_nil?: false, public?: true, default: []
    attribute :outcome_summary, :string, public?: true, constraints: [trim?: false]

    # The version of its workflow the task runs (`Workflows.running_version/2`), pinned as
    # its workflow starts; edits make newer ones, which it moves to only when told.
    attribute :workflow_version, :integer, allow_nil?: false, public?: true

    # The block the task is on in that version; nil before its workflow starts and after it
    # ends. No foreign key: blocks are replaced when their graph is saved, and the version
    # still has a block the latest graph removed.
    attribute :current_node_id, :uuid, public?: true

    # Traversals per arrow id (capped back arrows) and runs in a row per block id (self-loops).
    attribute :edge_counts, :map, allow_nil?: false, public?: true, default: %{}
    attribute :node_counts, :map, allow_nil?: false, public?: true, default: %{}

    # The coder picked when the plan was approved: the task's coder role blocks run it.
    attribute :pinned_coder_id, :uuid, public?: true

    # USD all the task's runs may spend; nil leaves it uncapped (`Weworkai.Agents.Budget`).
    attribute :budget_usd, :decimal, public?: true, constraints: [greater_than: 0]

    timestamps()
  end

  relationships do
    # Who works on the task now: the workflow sets it on entering a block (the agent running
    # it, the human deciding, nobody for "any human").
    belongs_to :assignee, Weworkai.Organization.Employee, public?: true
    belongs_to :workflow, Weworkai.Workflows.Workflow, allow_nil?: false, public?: true
    has_many :messages, Weworkai.Board.TaskMessage
    has_many :attachments, Weworkai.Board.TaskAttachment

    # Set only at creation (`create_subtask`), so sub-tasks form a tree.
    belongs_to :parent, __MODULE__, public?: true
    has_many :children, __MODULE__, destination_attribute: :parent_id, public?: true

    many_to_many :blockers, __MODULE__,
      through: Weworkai.Board.TaskDependency,
      source_attribute_on_join_resource: :blocked_id,
      destination_attribute_on_join_resource: :blocker_id,
      public?: true

    many_to_many :dependents, __MODULE__,
      through: Weworkai.Board.TaskDependency,
      source_attribute_on_join_resource: :blocker_id,
      destination_attribute_on_join_resource: :blocked_id,
      public?: true

    has_many :working_jobs, Weworkai.Scheduling.Job do
      filter expr(status in ^Activity.job_statuses())
    end
  end

  calculations do
    calculate :activity, :struct, Calculations.Activity, constraints: [instance_of: Activity]
    calculate :current_node, :struct, Calculations.CurrentNode, constraints: [instance_of: Node]

    # A blocker still open: the scheduler starts none of this task's agents.
    calculate :blocked, :boolean, expr(exists(blockers, status not in [:done, :canceled]))
  end

  # Names only, for prompts; the bytes load just before a run starts.
  aggregates do
    list :attachment_names, :attachments, :name do
      sort name: :asc
      default []
    end

    list :open_blocker_titles, :blockers, :title do
      filter expr(status not in [:done, :canceled])
      sort title: :asc
      default []
    end

    list :blocker_ids, :blockers, :id, default: []
    list :dependent_ids, :dependents, :id, default: []
    list :child_ids, :children, :id, default: []

    count :child_count, :children, filter: expr(status != :canceled)
    count :done_child_count, :children, filter: expr(status == :done)
  end
end
