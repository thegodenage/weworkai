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
    (`0 9 * * 1-5`, `*/30 8-18 * * *`, `@hourly`), parsed by `crontab`, any spaces between
    them. Any that parses and ever matches is accepted, however often it runs (runs close
    together are grouped). It reads as cron reads it: a step in the day or month field
    counts from 1 (`*/3` months: Jan, Apr, Jul, Oct), and with both a day of the month
    and a weekday given, either matching runs it (`0 9 1 * 1`: the 1st and every Monday).
    Refused: a sixth field (crontab would read it as a year, not seconds), a range that
    runs backwards (`30-10`, which crontab reads as every value), and @ names other than
    `@yearly`, `@annually`, `@monthly`, `@weekly`, `@daily`, `@midnight`, `@hourly`. The form previews its next three runs, with the year when
    it isn't this one;
- the **task** it creates: `name` (the title, with the slot's day, and its time too for an
  expression: "Daily GitLab digest · Wed 28 Oct", "Inbox · Wed 28 Oct 14:30"),
  `description` (what the agents are to do) and `repository`.

Code: `lib/weworkai/recurring/` (Ash domain `Weworkai.Recurring`; `Cron`, `Runner`).

## Firing

- `next_run_at` (UTC) is the cron's next slot (`Runner.next_run/2`), recomputed on every
  save and fire; a paused cron has none. A time DST skips runs when the clocks resume; one
  they pass twice, the first time only, except for an expression with a `*` hour (`0 * * * *`,
  `*/30 * * * *`), which goes on through the repeated hour as cron does, so it loses no
  runs (nor its day's stack).
- The scheduler's tick (docs/scheduler.md) calls `Runner.start_due/1` first. A due cron is
  **claimed** (`last_run_at`, the next `next_run_at`; only while `next_run_at` is still the
  one read, so a tick and a Run now on the same slot, or an edit saved meanwhile, make one
  run, not two) before its task is created
  (`Task.create_from_cron`) and **moved to todo**, exactly as a person moving it would: the
  workflow's version, problems and refusals apply. Every run creates its own task, whether
  or not the last one is still open.
- **Grace window**: a slot fires up to 60 minutes late (`Runner.grace_minutes/0`). When
  several slots have come since the cron last fired (the app wasn't running), only the
  newest one within the window fires, once; the older ones are skipped, the first of them
  recorded in `last_skipped_at` (an hourly cron down for three hours: the last hour
  fires; a half-hourly one down 50 minutes: the later slot fires, the earlier is missed).
  With none within the window, no task is made. The Recurring tab shows the missed slot
  until the run after the catch-up clears it, and follows fires and edits live
  (`"crons"` topic).
- A task that can't start stays in backlog; the cron shows why (`last_error`) and a
  `cron_failed` notification goes out. **Run now** fires a cron at once, its slot being now.
- Deleting a cron keeps its tasks and groups (their `cron_id` is nilified). A task keeps
  its cron's time zone (`tasks.cron_timezone`), so its scheduled time reads the same, and
  a stack of cron runs keeps its CRON chip and time span.

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
  first into it, once the second exists. Grouping is best effort: when it fails (the
  first run was just deleted), the new run goes on ungrouped and still starts. A run a person moved into a group of their own
  starts none; one a person took out of a group (Ungroup, or "No group": `tasks.apart`)
  starts none either, and the day's runs after it stay apart too.
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
