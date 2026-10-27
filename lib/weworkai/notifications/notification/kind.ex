defmodule Weworkai.Notifications.Notification.Kind do
  use Ash.Type.Enum,
    values: [
      started: [description: "An agent started working on the task"],
      plan_ready: [description: "A plan waits for review"],
      needs_answers: [description: "An agent waits for answers"],
      ready_for_review: [description: "A custom agent is done; a human reviews"],
      ready_to_merge: [description: "The reviewers are done; the branch waits to be merged"],
      answer_ready: [description: "An agent answered a question about the task"],
      stage_skipped: [description: "No agent for a review stage, so it was skipped"],
      agent_failed: [description: "An agent run failed"],
      agent_stalled: [description: "An agent run went silent or ran too long, and is retried"],
      decision_needed: [description: "The task reached a human block of its workflow"],
      workflow_stuck: [description: "The task's workflow has no way on from where it is"],
      budget_warning: [description: "A task or an agent spent 80% of its budget"],
      budget_reached: [description: "A task or an agent spent its budget; no new run starts"],
      unblocked: [description: "The task's last open blocker closed; its agents may start"]
    ]
end
