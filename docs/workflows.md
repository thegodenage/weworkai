# Workflows (user-defined)

A **Workflow** is a graph of blocks and arrows. Every task runs one workflow; the engine
(`Weworkai.Workflows.Engine`) interprets the graph as a state machine. It replaced the
hard-coded planner → coder → review flow, which is now the seeded default workflow
(docs/workflow.md describes the agents, prompts and human loop it runs).

Code: `lib/weworkai/workflows/` (Ash domain `Weworkai.Workflows`; resources
`Workflow`, `Node`, `Edge`; the pure `Graph`; the `Engine`).

## Blocks (nodes)

| kind | names | entering it |
|---|---|---|
| `agent` | an agent employee **or** a role (`agent_role`: "any planner") | queue a run for its agent; the role decides prompt, schema, profile and folder (planner, coder, reviewer, qa, merger, custom) |
| `human` | a human employee, or nobody ("any human") | task → `await_human_supervision` (assignee = that human, or nobody for "any human"); the task page shows one decision button per arrow out |
| `column` | `column_status` (a board column) | move the task there; `done` / `canceled` end the workflow (`current_node_id` → nil); any other column passes the task on along its unnamed arrow, or keeps it there without one (moving it to todo then starts the workflow over, since entering that column again would only move it back) |
| `group` | children (blocks with `group_id`), rectangle geometry | enter its entry block (the child no arrow from a sibling points to; with a loop drawn inside, where every child has one, the first drawn of those that reach all the others); an outcome a child has no arrow for (one that never runs out) leaves the group by the group's own arrows, so Reviewer `findings` → Coder inside a group still leaves it on `clean`. An arrow from outside straight to a child (or a human starting one) enters the group too: its self-loop counts runs afresh |
| `triage` | nothing (no employee, role or column) | runs nothing: ends at once with the worst severity among the round's open findings (`high`, `medium`, `low`), or `clean` without any (`Graph.triage/1`), and routes on like an agent's outcome. Put it after a reviewer to send only serious findings back: `high` → Coder (capped), always → Approve. Its arrows into a coder block carry the findings (the fix prompt lists all of them, low ones too) and count towards the fix-round limit, every condition but `clean`. With no arrow for its outcome the task waits on it for a human (`workflow_stuck`) |

Exactly one **start** block per workflow: the one marked `start`, else the only top-level
block no arrow points to. Kanban column while an agent block runs: planner / coder /
custom → `in_progress`, reviewer / qa → `review` (`todo` / `review` until the scheduler
picks a human-started run up).

**Which agent runs a block.** Nobody assigns a task: moving it to todo starts its
workflow (its start block, or the block it is on), and the workflow assigns it. A block
naming an agent runs that agent (it must be able to run). A role block runs the first
agent in the role that can run (by id); a coder role block runs the task's
`pinned_coder_id` instead when the plan's approval picked one (binding: it must be able to
run). **Default agents**: a role block whose role has no agent at all, while a connector
is connected, makes one first (`Organization.DefaultAgent`): an agent employee named after
the role ("Planner", "Docker reviewer", …) on the first connected connector by name, with
the first model it offers and the role's default prompt. It stays an ordinary employee,
configurable on the Employees page, and the role's later blocks run it; a role with any
agent never gets one. So a fresh install runs the template workflows with only a connector.
Deleting a default agent doesn't stick: the next block in its role makes it again. To keep
a role's blocks from running (say, to skip reviews), take its blocks out of the workflow,
or keep an agent in the role without a model (its reviewer / qa blocks are then skipped).
When the default agent can't be made (the connector can't list its models, or lists none),
nobody is made and the block is refused with the reason, a reviewer / qa block too, so the
task stops with a human rather than skipping its review ("Coder can't run: No coder agent
yet, and none could be made on Claude: Claude bridge is not running. …"). A same-named
employee makes it "Planner 2". Asking about a task with no planner at all makes the default
planner to answer (docs/workflow.md).
When the block about to run has no agent that can, the action is refused naming the
block and what is missing ("Coder can't run: No coder agent yet. Add one on the
Employees page.", "Ada can't run: Ada has no model yet. …"); the card stays put. A
reviewer / qa role block with no agent that can run is skipped with a `stage_skipped`
notification and routes on as if it found nothing new (Continue to it is refused instead
when agents exist but all lack setup). **The assignee is derived**: entering an agent
block makes its agent the task's assignee (reviewers too), a human block its human (nobody
for "any human"), so the card shows who works on it now. The board drawer shows it read-only;
the create form has no assignee.

## Arrows (edges)

`from → to`, optional **condition** (outcome label; nil = "always") and **iterations**.

- Outcomes an agent block ends with: planner `plan_ready`, `needs_answers` (the plan has
  questions); coder `done`, `blocked`; reviewer / qa `clean`, `findings`; merger `merged`,
  `blocked`; custom `done`.
  A triage block ends with `high`, `medium`, `low` or `clean`.
  A reviewer's outcome counts **the round's findings so far** (its own plus earlier
  reviewers' since the coder last finished), so a second reviewer can carry the first's
  findings back to the coder. Each finding records the block that found it
  (`block_id`): a block reviewing again in the same round (a self-loop, a group's loop)
  replaces its own earlier findings, so the coder never gets one twice. Human blocks: one arrow per decision, each named (the
  button's label, e.g. `accepted`, `not accepted`). Columns: unnamed arrows only.
- Routing an outcome (`Graph.route/4`, in this order):
  1. `needs_answers` / `blocked` with no arrow named so (nor an arrow of a group around
     the block) → **pause** on the block for a human's answers; answering resumes the same
     block (built-in, not drawn). Unnamed arrows never take them.
  2. a **self-loop** for the outcome (or unnamed) while the block ran fewer times *in a
     row* than its `iterations` (`node_counts`; review ×2 = the reviewer runs twice).
     A group's count goes up each time its loop re-enters it and back to 1 when any other
     arrow does; with no count (a human started the task on one of its blocks directly:
     drag into review, Continue) it counts as having run once.
  3. the arrow named for the outcome unless exhausted, else the unnamed one.
  4. falling out of an exhausted loop or capped arrow: the **one** arrow left, if exactly
     one (e.g. findings after the last fix round → `clean`'s arrow, findings attached);
     for an outcome falling out of a group, the group's one arrow left.
  5. nothing of the block's own fits, inside a group: the group's own arrows (the outcome
     ends the group).
  6. nothing fits → the task waits for a human with a system message ("Coder has no arrow
     for “done”.") and a `workflow_stuck` notification.
- **Back arrow**: an arrow into a block that can reach its source again and lies no
  deeper (breadth-first from the start). It needs `iterations` = max traversals
  (`edge_counts`, per task); once exhausted it is skipped. Arrows out of human blocks need
  no cap: a human decides each time. A cap set on one still holds: once used up (a loop:
  the block's runs in a row) its decision button is no longer offered.
- Re-entering a planner or coder block resumes its conversation (`plan_session_id` /
  `code_session_id`, one per role per task) with the prompt for how it was entered:
  review findings → the fix prompt ("fix round N of M": `review_round` counts fix rounds,
  M sums the caps of the arrows carrying findings into coder blocks, named `findings` or
  unnamed out of a reviewer or group, any but `clean` out of a triage block; a self-loop ×N sends them back N − 1 times), a human decision →
  "decided: <label>", Continue or a move to todo → carry on, an answer / comment → those,
  any other arrow (a self-loop, a second block in the role) → "sent to you again, now as
  the step <label>". Two blocks in one role (Coder A, then Coder B) share that one
  conversation on purpose: B knows what A did and works in the same worktree; a block
  naming another agent resumes it too (with that agent's model). A conversation lives on
  the bridge it ran on (`plan_session_connector_id` / `code_session_connector_id`): an
  agent on another connector starts its own (the fresh prompt, plus the fix prompt when
  findings sent it), and Ask forks only a conversation on the answerer's connector. Reviewers and custom
  agents start fresh every time. A coder block creates the task's worktree on its
  first entry; reviewer blocks need one.
- Agent failures → `await_human_supervision` on the same block + Continue (as before).
  A block the workflow can't enter (its agent can't run, no worktree…) is where the task
  then waits, with a `workflow_stuck` message saying why; an arrow into a group waits on
  the group's first block, so Continue's default runs it.
- **A block's own instructions** (`workflow_nodes.prompt`, agent blocks only, at most
  20,000 characters, trimmed): every run the block starts gets them under
  "# Instructions for this step (from the workflow)". A fresh run has them after the
  role's instructions and before the task (`Prompts.plan/2` … `task/2`); a resumed
  conversation (fix rounds, a decision, answers, Continue) gets them first
  (`Prompts.for_step/2`), so cutting a prompt to the bridge's limit never cuts them. The
  role's prompt and JSON schema stay as they are, and the agent's own settings still apply.
  Only that block's runs get them: another block of the same role in the workflow doesn't.
- **A block's own timeouts** (`stall_timeout_minutes`, `turn_timeout_minutes`, agent
  blocks only, 1–1440, blank = the defaults 15 and 120): copied onto each job the block
  queues. A run silent or running that long is stopped and retried, then handed to a human
  (docs/scheduler.md, "Timeouts").
- **A merger block** (role `merger`) merges the task's branch with no human asked: into
  its `merge_branch` (`workflow_nodes.merge_branch`, the inspector's "Merge into"; blank =
  the branch checked out in the task's repository). It needs a worktree, "Nothing to merge
  yet" otherwise: an arrow into it leaves the task waiting on it, and a workflow that
  starts on it refuses the move to Todo, like one that starts on a reviewer. `merged` routes on (e.g. → Column Done); `blocked`
  (a conflict it can't settle, a dirty checkout, a missing branch) pauses on the block
  unless an arrow takes it, and Continue (or a blank "Merge with agent", or one into its
  own branch) runs it again. A merge there into another branch runs beside the graph and
  leaves the task on the block. A reported merge into another branch than the one asked
  for (or none) counts as `blocked`. Only merger blocks may name a
  branch, and it must look like one (`Graph.branch_name?/1`). Example automatic merge:

  ```
  Docker reviewer --clean--> Merger (release) --merged--> Column Done
  ```

## Default workflow (seeded by migration, first in list)

Drawn in two rows (it reads at about 60% on a 1440px screen): Planner, Approve plan,
Coder, Reviewer above; Done, Approve, Docker reviewer below.

```
Planner --plan_ready--> Human "Approve plan" --approved--> Coder --done--> Reviewer
Reviewer --(always)--> Docker reviewer
Docker reviewer --findings (max 3)--> Coder      Docker reviewer --clean--> Human "Approve"
Human "Approve" --accepted--> Column Done        Human "Approve" --continue--> Coder
```

All role blocks, "any human" human blocks, so it works whatever employees exist. Both
reviewers see every round and the docker reviewer's arrow carries both reviewers'
findings, which keeps the old behaviour exactly: at most three fix rounds, then ready to
merge with the findings attached. A plan with questions pauses on the Planner
(`needs_answers`).

## Templates

Seeded example workflows (`workflows.template`: `default`, `double_review`). They are
**ordinary workflows**: they run tasks, can be renamed, reordered, edited and deleted like
any other (only the last workflow can't be deleted, template or not). "New from template"
on `/workflows` (`/workflows/from-template`) offers Blank plus every template still there,
and copies the chosen one with `copy_graph` (new ids, its problem count; the copy is no
template). Editing a template therefore changes what later copies start with; the list
marks templates with a "Template" badge so that is visible. The migrations mark the
seeded default (`template = default`) and seed "Double review" at the end of the list
with fixed ids (`d0ab1e00-5e7e-4000-8000-…`, inserted with `ON CONFLICT DO NOTHING`). The
e2e reset restores the templates as the migrations seed them, from a snapshot
(`priv/e2e/templates.json`, checked against the migrations by `Weworkai.E2ETest`;
`WRITE_E2E_SNAPSHOT=1 mix test test/weworkai/e2e_test.exs` rewrites it after a migration
changes a template), so a spec that saves one never leaks into the next run.

### Double review

Two rows (it fits the editor at 1440px): Planner, Approve plan, Coder, group "Full review"
(Reviewer → Docker reviewer) above; Done, Approve below.

```
Planner --plan_ready--> Human "Approve plan" --approved--> Coder --done--> Group "Full review"
Group "Full review": Reviewer --(always)--> Docker reviewer   (Docker reviewer is its exit)
Group --clean, loop ×2--> Group                Group --findings (max 3)--> Coder
Group --clean--> Human "Approve"
Human "Approve" --accepted--> Column Done      Human "Approve" --continue--> Coder
```

What runs (a reviewer's outcome counts the round's findings, so the docker reviewer's
outcome carries the code reviewer's findings too):

- **Clean**: Coder → Reviewer → Docker reviewer (pass 1, clean: the loop re-enters the
  group) → Reviewer → Docker reviewer (pass 2: the loop is used up) → Approve. Exactly two
  full reviews.
- **Findings** in either pass (from either reviewer): the loop only takes `clean`, so the
  findings arrow sends the task to the Coder straight away (fix round n of 3); a pass with
  findings is not repeated. The Coder's `done` enters the group through an ordinary arrow,
  which resets its count: **every review after a code change is a full ×2 again**
  (e.g. R, D(findings) → Coder → R, D, R, D → Approve).
- **Exhausted**: after three fix rounds, findings in a pass fall out to the one arrow left,
  `clean` → Approve, findings attached ("… still open after 3 fix rounds"). At most four
  reviews (eight passes, if every review fails in its second pass) and three fixes.
- Drag into review / Continue → Reviewer: fix rounds and counts afresh, two full passes.

## Human features on the graph

- **Move to todo** (board): runs the task's current block again, or the start block when
  it has none (new, ended, switched workflow, block removed) or is parked on a column
  block with no arrow on: starting over clears fix
  rounds, findings and counts, so the arrows' caps apply afresh. A task whose agent still
  works on it keeps that job. Refusals (an agent that can't run, no worktree…) keep the
  card where it was.
- **Plan view**: a comment or answers return to the block that asked (the current agent
  block, else the planner / coder with an arrow into the current block), without taking
  an arrow. "Ready for development" takes the **approval arrow**: from the plan's human
  block its arrow to a coder block (`approved` first), or from a planner paused with
  questions its `plan_ready` arrow on to that. A coder pick shows only when that coder
  block is a role block with several coders that can run; the pick pins that coder for the
  task's coder role blocks (`pinned_coder_id`). With one coder, or a block naming its agent,
  the plan simply goes on (and with none the button is disabled).
- **Decisions**: the task page shows a button `#decide-<edge id>` per arrow out of the
  human block the task waits on (`Board.decide_task/2`; the approval arrow is the plan
  control instead), plus a `decision` message "Decided: <label>".
- **Continue** targets the workflow's agent and human blocks (`#continue-task-<node id>`,
  "Continue → <block label>"; reviewer blocks once there is code) and `done`. Default:
  the agent block the task is on, else the first reviewer once it has code, else the
  start. A reviewer target starts the review over (fix rounds and counts afresh).
- **Drag into review** = the first reviewer block (breadth-first), counts afresh.
- **Done / canceled** (board, Continue, a column block) end the workflow.
- Entering a human block notifies: nothing extra after a planner (`plan_ready` was
  sent), `ready_to_merge` after a reviewer, else `decision_needed`. A plan waiting at a
  human block keeps stage `planning`, so the plan view stays open; other human blocks
  clear the stage.
- **Ask** and the activity spinner are unchanged (not part of the graph).

## Data

- `workflows`: name, position (order; first = default for new tasks), `version` (1 when
  created, bumped by every graph save), `problem_count` (the problems it was saved with; > 0 = runs no task),
  `template` (which seeded example it is, else nil; only migrations set it).
- `workflow_nodes`: workflow, kind, employee_id?, agent_role?, column_status?, group_id?
  (parent group), label, x, y, width?, height?, start, color? (a group's, editor only),
  prompt? (an agent block's own instructions; saved, copied and undone with the graph),
  stall_timeout_minutes?, turn_timeout_minutes? (its runs' timeouts; nil = the job's defaults),
  merge_branch? (a merger block's target; nil = the checked-out branch).
  Employee removed → `employee_id` nilified; entering such an agent block hands the task
  to a human, and the editor flags it.
- `workflow_edges`: workflow, from_node, to_node, condition?, iterations?, from_port,
  to_port (`top` / `right` / `bottom` / `left`, for drawing), pinned (its dots were chosen
  by hand; drawing only).
- `workflow_versions`: workflow, `number` (unique per workflow), `graph` (the editor's
  params shape, ids as stored), `problem_count` (as saved), inserted_at. See "Versions".
- task: `workflow_id` (required, default = first workflow), `workflow_version` (the version
  it runs, pinned as it enters its workflow), `current_node_id` (no foreign key: a block of
  that version, which the latest graph may have removed; `current_node` reads it from the
  version),
  `edge_counts` (edge id → traversals), `node_counts` (node id → runs in a row),
  `pinned_coder_id` (the coder picked at plan approval; coder role blocks run it),
  `plan_session_connector_id` / `code_session_connector_id` (the connector each
  conversation ran on; nil = recorded before, resumed anywhere),
  `assignee_id` (set by the engine: who works on the block the task is on).
  Switching a task's workflow starts it over (place and counts cleared, its agent stopped,
  pinned to that workflow's latest version).
- The migration seeded the default and backfilled every task with it, placing each on the
  block its stage and status matched (planning → Planner, plan awaiting approval →
  Approve plan, coding → Coder, code_review → Reviewer, qa → Docker reviewer, ready to
  merge → Approve, else none) and its fix rounds onto the findings arrow.

## Versions

Every graph save is an immutable `Workflows.Version`, numbered by the workflow's `version`
(creating a workflow records v1; a save records the next one in the same transaction).
The migration made every workflow's graph as it was its v1 (`version` restarted at 1) and
pinned every task to it.

- **A task runs its pinned version** (`Workflows.running!/1`): while it is on a block
  (`current_node_id`), the engine, the task page, Continue and the audit timeline read the
  graph of `task.workflow_version`, rebuilt from the version with today's employees (a
  removed one's blocks name nobody, as stored blocks do). So editing a workflow never
  moves, strands or reroutes a task already in it: it finishes on the graph it started.
- **Not on a block** (new, ended, switched workflow): the step runs the workflow's latest
  version and pins it (`running_version/2`; the engine writes `workflow_version` with every
  place). A task parked on a column block with no arrow on starts over on its pinned one.
- **Problems are the version's**: a step is refused when the version it runs has problems
  with today's employees, so a draft saved meanwhile stops no task already in the workflow;
  an agent finishing routes on by its pinned version.
- **Move to the latest** (`Board.upgrade_task_workflow/1`, the task page's "Move to vN"):
  allowed when the latest has no problems and still has the task's block (ids are kept
  across saves); place and counts carry over, an agent working on the block carries on,
  and an `upgrade` event ("Moved from v2 to v3") marks the audit timeline. Otherwise the
  page shows "vN available" with why ("Its block is not in v3: it finishes on v2.").
- **History** (editor, the version chip at the toolbar's end): every version newest first,
  when it was saved, its blocks, problems and the tasks on a block of it; **Restore** saves
  an older version's graph as the newest (`Workflows.restore_version/2`, keeping its ids so
  tasks pinned to it can move up) and reopens the editor on it.
- The e2e reset records each template's v1 afresh from the restored graphs.

**Saving a graph** (for the editor): `Workflows.save_graph(workflow, %{nodes: [...],
edges: [...]})` (atom or string keys; arrows name their ends `from` / `to`) checks it with
`Graph.draft/2` and replaces the graph in one transaction **problems and all**: a graph
with problems is a draft, its `problem_count` recorded, and returned as `problems`
(`[%{id: id, message: text}]`, `id` being the block's or arrow's id as sent, nil = the
workflow as a whole). Only a graph that can't be stored (a field that doesn't cast,
duplicate ids, arrows to missing blocks, a block inside a non-group or inside itself)
changes nothing and returns `{:error, problems}`. `workflow.version` must be the stored
one (`optimistic_lock`): a save drawn from an older version returns `{:error, :stale}`.

**Workflows with problems run nothing.** Every human step on a task (move to todo or
review, decisions, approval, answers, comments, Continue to a block) is refused with
"The workflow “X” has 2 problems to fix in its editor before tasks can run it."
(`Board.Task.Changes.Transition`); Continue → Mark done still works. An agent finishing
on a workflow saved with problems meanwhile keeps its result and the task waits for a
human with that message. The workflows list shows a "N problems" badge, the task form's
and drawer's workflow select "(has problems)". A new empty workflow starts with one
("Add a first block"); a copy takes its source's count. Ids the workflow already has are kept (tasks keep
their place and counts); others (the editor's own, like `n1`) get new uuids, mapped in
the result's `ids`.

The count is also kept right without an edit: removing an employee (its blocks then name
nobody) or changing an agent's role (the outcomes its blocks' arrows may name) recounts
every workflow's problems (`Workflows.recount_problems!/0`, the `:recount` action, which
leaves `version` alone), group arrows included. An agent losing its model or connector is no graph problem: the
step that would run it is refused, naming what is missing.

Validation on save: one start block; every block reachable from it; self-loops need
iterations ≥ 1; back arrows from non-human blocks need iterations; human blocks need ≥ 1
named arrow out and every arrow out named; arrow conditions are outcomes the agent's role
ends with (a triage block's severities or `clean`), and none out of a column; triage
blocks name no employee or column; a group's named arrows an outcome that can leave it
("Nothing leaves Build with “done”: its blocks leave it with clean or findings"); one
arrow per block and condition; agent blocks name
an agent employee or a role (not both), human blocks a human or nobody, columns a status;
groups non-empty, with exactly one entry block, inside groups only and never inside
themselves; arrows end on existing blocks.

## Pages

- `/workflows` (sidebar "Workflows"): list (name, block count, tasks using it, "Default"
  on the first, "Template" on the templates), New = an empty canvas or a copy of a chosen
  workflow, New from template = Blank or a copy of a template (described), both opened in
  the editor; rename, move up / down, delete (refused while tasks use it, and for the last
  one).
- `/workflows/:id`: the editor (below).
- Task create form and board drawer: a workflow select; cards, the drawer and the task
  page show the block the task is on. Switching the drawer's workflow asks first once the
  task is somewhere in its workflow (it starts over; a working agent is stopped).
- Decisions on the task page take an optional note: it goes into the "Decided: …" message
  and, as "# Their comment", into the prompt of the planner / coder the arrow resumes, or
  ahead of the prompt of an agent that starts afresh (a reviewer, a custom agent, a first
  run), with the decision's name.

## Editor (W2)

`WeworkaiWeb.WorkflowLive` renders the shell (toolbar, palette, canvas layers, inspector)
once, with the stored graph (`Graph.validate/2`'s params shape), its problems and a catalog
(employees, roles with their outcomes, columns, group colours) as JSON data attributes,
under `phx-update="ignore"`. The external hook `WorkflowEditor` (`assets/js/workflow_editor/`)
owns everything after that; the server only answers two events, both with a reply:

- `validate` (debounced after every change) → `%{problems: [...]}` (`Workflows.problems/1`);
- `save` (with the `version` the graph was drawn from, `data-version`) →
  `%{ok: true, ids: %{sent => stored}, problems: [...], version: n}`, `%{ok: false,
  stale: true, version: n}` (saved elsewhere since: a banner offers "Load theirs" or
  "Overwrite with mine", which saves again with `n`) or `%{ok: false, problems: [...]}`
  (can't be stored). With problems the button says "Saved as draft".

JS modules: `model.js` (the graph as immutable data and every edit as a pure function:
add, move, connect, group / ungroup, duplicate, remove, membership, id remapping),
`geometry.js` (ports, bezier curves, self-loop arcs), `history.js` (undo / redo of whole
graphs), `catalog.js` (labels, tones, which outcomes an arrow may name), `render.js`
(keyed HTML blocks and groups, one SVG for arrows, HTML label pills and re-attach handles),
`inspector.js` (right panel), `drafts.js` (the unsaved graph per tab), `editor.js`
(pointer and keyboard gestures, camera, the two events, unsaved-changes guards). No
dependencies.

- **Drafts**: every change writes the unsaved graph (with its version and time) to
  sessionStorage (`wf-draft:<workflow id>`); a save or undoing back to the stored graph
  clears it. On load a draft that differs from the stored graph is offered back
  ("You have unsaved changes from 15:12." Restore / Discard; "…made before this workflow was
  saved elsewhere" when its version is older, whose save then hits the stale banner). So a
  reload, a redeploy or a LiveView that had to remount loses nothing.

- Canvas: drag the background (or space-drag, middle button) and scrolling (wheel, two
  fingers on a trackpad; ⇧ scroll sideways) pan; pinch, ⌘ / ctrl + scroll and the buttons
  zoom around the pointer; fit-to-view (also on load); 20px dotted grid, blocks snap to it.
- Palette: sections Roles ("Any coder"…), Agents (each agent), Humans ("Any human" and
  each human), Kanban columns (all but "await human supervision"), Structure (Group, Triage). Each
  folds (remembered per browser), shows its count and keeps its header in view while its
  items scroll; search filters it, opens every section with a match and counts matches
  ("1/6"). Drag onto the canvas, or click / Enter to add in the middle of the view (below
  the last one added, with room for an arrow). The first block added is the start.
- Blocks: click / shift-click / ⇧-drag rubber band select, drag moves the selection
  (groups take their contents), arrows keys nudge, double-click or Enter renames, ⌫
  deletes (with its arrows), ⌘D duplicates, ⌘C / ⌘V copy, ⌘A all, right-click menu
  (rename, set as start, duplicate, group, ungroup, delete). Four dots per block show on
  hover.
- Arrows: drag from a dot onto another block's dot (or its body: the dot facing the
  arrow's source). Onto its own block = a loop, ×2 by default. Moving a block re-routes
  its arrows between the sides the two blocks face each other with, unless the arrow's
  dots were chosen by hand (an end dragged onto a dot: `pinned`; the inspector's "Let the
  editor pick them" undoes that). A new arrow is selected and
  its condition focused: agent blocks pick one of their role's outcomes or "always", human
  blocks type the decision's name (suggestions offered), columns take none, groups take
  any outcome. Iterations: a loop's runs in a row, else the arrow's maximum. A selected
  arrow's two end handles drag onto another dot to re-attach it.
- Groups: ⌘G around the selection (or the palette's empty Group), titled, coloured
  (`workflow_nodes.color`, editor only), resizable from the corner, with their own dots.
  Membership is geometry: a block belongs to the smallest group its centre lies in, so
  dropping a block in or out of a rectangle changes its group, and groups nest (the engine
  resolves nested groups). Deleting or ungrouping a group keeps its blocks.
- Inspector: name, who runs / decides it or which column, an agent block's own
  instructions (`#wf-inspector-prompt`: a textarea that grows with its text; it commits as
  it loses focus, ⌘S included; blocks with instructions show a speech-bubble mark whose
  tooltip previews them), colour, start, arrows out, the item's problems; for an arrow its
  From / To blocks (re-attaching without the mouse), condition and iterations; with
  nothing selected the workflow's problems (click one to reveal it) and the shortcuts, or
  on an empty canvas four first steps. A redraw while a field is being typed in (a
  validation reply) keeps what was typed.
- Quick add: double-click the canvas (or its menu's "Add a block here…") for a search over
  the palette at that point; ↑ / ↓ and Enter add the block there, Escape closes it. An empty
  canvas offers "Add a planner" and "Find a block".
- Dropping a palette block onto a block's dot places it beyond that side (clear of other
  blocks: sideways, then further out), connected from that dot, and selects the new arrow
  for its condition (one undo step).
- Dragging a block shows snap guides where its edges or centre line up with a block or
  group near it, and snaps onto them within a few screen pixels.
- Arrows meeting on one dot fan out along its side, in the order of their other ends, and
  labels that would overlap move apart (by their measured sizes). The selected arrow's label has a × that deletes it;
  focusing a label (Tab) selects its arrow and Enter edits its condition.
- Undo / redo select what they bring back (a deleted block, else a deleted arrow).
- The page's own messages (a lost connection) sit below the toolbar, clear of Save. The
  notification toasts' six seconds only run while a toast shows and the pointer or focus
  isn't on them; "+N more" opens the bell's list, "Dismiss all" clears them.
- Problems show live as red badges on blocks and dashed red arrows, a count in the toolbar
  and the list. An agent block whose employee was removed shows "Its agent was removed".
- Save (button, ⌘S) with a dirty indicator; ⌘Z / ⇧⌘Z undo and redo the editor's graph
  (also across a save: saved ids are mapped into the history). Leaving with unsaved
  changes asks once: reload / close (beforeunload), LiveView links and back / forward
  (`phx:before-navigate`), a notification row or toast opening its task (`app:leave`, a
  cancelable window event the toasts dispatch). A "leave" clears nothing: the draft is
  still offered when the editor opens again.
