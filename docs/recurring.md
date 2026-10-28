# Recurring workflows (crons)

Some workflows should run on their own: every weekday at 9 to fetch the newest GitLab
interactions, every half hour during the day to check for comments on posts. The
**Recurring** tab (`/recurring`, `WeworkaiWeb.RecurringLive`) holds **crons**
(`Weworkai.Recurring.Cron`, table `crons`), each naming:

- the **workflow** it runs (any workflow; one that crons run can't be deleted);
- **when**, in one of two modes (`mode`), both on the wall clock of an IANA time zone
  (`timezone`, the browser's to start with; DST is followed, with the `tz` database):
  - `weekly` ("Days & time"): ISO weekdays (`days`, 1 = Monday) at a time of day (`at`);
  - `expression` ("Cron expression"): five fields, minute hour day-of-month month weekday
    (`0 9 * * 1-5`, `*/30 8-18 * * *`, `@hourly`), parsed by `crontab`. Any that parses and
    ever matches is accepted, however often it runs (runs close together are grouped);
    the form previews its next three runs;
- the **task** it creates: `name` (the title, with the slot's day, and its time too for an
  expression: "Daily GitLab digest · Wed 28 Oct", "Inbox · Wed 28 Oct 14:30"),
  `description` (what the agents are to do) and `repository`.

Code: `lib/weworkai/recurring/` (Ash domain `Weworkai.Recurring`; `Cron`, `Runner`).

## Firing

- `next_run_at` (UTC) is the cron's next slot (`Runner.next_run/2`), recomputed on every
  save and fire; a paused cron has none. A time DST skips runs when the clocks resume; one
  they pass twice, the first time, and an expression's match in the repeated hour never
  fires twice.
- The scheduler's tick (docs/scheduler.md) calls `Runner.start_due/1` first. A due cron is
  **claimed** (`last_run_at`, the next `next_run_at`) before its task is created
  (`Task.create_from_cron`) and **moved to todo**, exactly as a person moving it would: the
  workflow's version, problems and refusals apply. Every run creates its own task, whether
  or not the last one is still open.
- **Grace window**: a slot fires up to 60 minutes late (`Runner.grace_minutes/0`). One
  missed by more (the app wasn't running) is skipped: no task, `last_skipped_at` records it,
  and the next slot is the first within the window, so after a long outage the newest slot
  still within it fires once (an hourly cron down for three hours: the last hour fires).
  The Recurring tab shows the missed slot until the run after that catch-up clears it.
  `@reboot` parses but has no dates, so it is refused.
- A task that can't start stays in backlog; the cron shows why (`last_error`) and a
  `cron_failed` notification goes out. **Run now** fires a cron at once, its slot being now.
- Deleting a cron keeps its tasks and groups (their `cron_id` is nilified).

## Tags and the CRON tag

Tasks carry free **tags** (`tasks.tags`, at most 10 of 30 characters), typed as one
comma-separated line in the New task form and the board drawer, shown as chips on the card
and filtered on with the board's Tag filter. A cron's tasks are created with the tag
**CRON** (`Task.cron_tag/0`, sky, ↻), and only they show their **scheduled time**
(`tasks.cron_run_at`, the slot they ran for, on the cron's clock) on the card and as
"Scheduled" in the drawer. Cron tasks arrive on boards live (`create_from_cron` is
published on `"tasks"`), even when their workflow refused to start them.

## Groups

A **task group** (`Board.TaskGroup`, `tasks.group_id`) shows its tasks as **one stack per
column** on the board: dashed, with layered edges, the group's name and `×N`, and for a
cron's group the CRON chip and the span of its run times ("08:00–14:30"). Clicking a stack
lists its tasks; each still drags to another column and opens on its own, and "Ungroup"
puts them all back. A group goes when its last task leaves it (`DropEmptyGroup`).

- **A cron's runs close together** are grouped by themselves: a run joins its previous
  run's group when it comes at most 60 minutes after it on the same day of the cron's
  clock (`Runner.group_gap_minutes/0`), so a half-hourly cron leaves one stack a day. The
  second close run creates the group ("Inbox · Wed 28 Oct", `cron_id` set) and moves the
  first into it. A run a person moved into a group of their own starts none.
- **Any tasks** can be grouped from the board drawer's Group control: an existing group,
  or "New group…" with a name; "No group" takes a task out.
- **Dragging a whole stack** to another column moves every task of the group in the
  column it left, after the browser confirms ("Move all 12 tasks of “Inbox · Mon 02 Nov”
  to Done?"). Each moves as if dragged alone (`Board.move_task`), so a refusal (an agent
  that can't run, a workflow with problems) keeps that one where it was and is told in one
  flash ("Moved 10 of 12. …"); the others move.
- On the board, ungrouped cards keep their per-status streams; each column has a second
  stream (`<status>_groups`) of stacks. `BoardLive.regroup/4` marks the groups and columns
  a changed task left or entered, and `flush_stacks/1` redraws each of them once per event
  (a stream item inserted and then deleted in the same render would stay).
