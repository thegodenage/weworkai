const { test, expect } = require("@playwright/test")
const { AGENT_WAIT, removeTasks, setColorScheme, visitConnected } = require("./helpers")
const { addBlock, block, connect, drag, edges } = require("./editor_helpers")

// Draws a workflow with the real mouse in the editor (/workflows/:id), saves it, reloads it,
// and runs a task through it against the fake bridge:
//
//   Group 1 [ Coder --done--> Reviewer (×2 loop) --> QA ] --> Approve
//   Approve --accepted--> Done        Approve --not accepted--> Group 1
//
// Own connector, agents and workflow (prefix "AE"); its decision notifications would
// disturb task_review.spec.js's count, so it runs after (playwright.config.js).
const PREFIX = "AE"
const CONNECTOR = `${PREFIX} Bridge`
const WORKFLOW = `${PREFIX} drawn`
const AGENTS = [
  { name: `${PREFIX} Coder`, role: "coder" },
  { name: `${PREFIX} Reviewer`, role: "reviewer" },
  { name: `${PREFIX} QA`, role: "qa" },
]
const SHOTS = "test-results/screens"

test.use({ viewport: { width: 1600, height: 1000 } })
test.setTimeout(180_000)

async function removeWorkflows(page) {
  await visitConnected(page, "/workflows")
  const buttons = page.locator(`[aria-label^="Delete ${WORKFLOW}"]`)
  for (let count = await buttons.count(); count > 0; count--) {
    await buttons.first().click()
    await expect(buttons).toHaveCount(count - 1)
  }
}

async function cleanUp(page) {
  await removeTasks(page, `${PREFIX} `)
  await removeWorkflows(page)
}

async function setUp(page) {
  page.on("dialog", (dialog) => dialog.accept())

  await visitConnected(page, "/connectors/new")
  await page.locator("#connector-form input[name='form[name]']").fill(CONNECTOR)
  await page.locator("#connector-form").getByRole("button", { name: "Save" }).click()
  await page.locator(`[aria-label="Connect ${CONNECTOR}"]`).click()
  await expect(page.locator(`[aria-label="Connect ${CONNECTOR}"]`)).toHaveText("Reconnect")

  for (const { name, role } of AGENTS) {
    await visitConnected(page, "/employees/new")
    const form = page.locator("#employee-form")
    await form.locator("select[name='form[kind]']").selectOption("agent")
    await form.locator("input[name='form[name]']").fill(name)
    await form.locator("select[name='form[agent_role]']").selectOption(role)
    await form.locator("select[name='form[connector_id]']").selectOption({ label: `${CONNECTOR} (Connected)` })
    await form.getByRole("button", { name: "Save" }).click()
    await page.locator(`[aria-label="Configure ${name}"]`).click()
    await page.locator("#agent-form select[name='form[model]']").selectOption("claude-opus-5-5")
    await page.locator("#agent-form").getByRole("button", { name: "Save" }).click()
    await expect(page.locator("#agent-form")).toHaveCount(0)
  }
}

const problems = (page) => page.locator("#wf-problem-count")

test("draws a workflow in the editor and a task runs it", async ({ page }) => {
  await setUp(page)

  // A new workflow opens as an empty canvas with a hint.
  await visitConnected(page, "/workflows/new")
  await page.locator("#workflow-form input[name='form[name]']").fill(WORKFLOW)
  await expect(page.locator("#workflow-form select[name='form[source_id]'] option:checked")).toHaveText("An empty canvas")
  await page.locator("#workflow-form").getByRole("button", { name: "Save" }).click()
  await expect(page.locator("#workflow-name")).toHaveText(WORKFLOW)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await expect(page.locator("#wf-empty")).toBeVisible()
  await setColorScheme(page, "light")
  await page.screenshot({ path: `${SHOTS}/editor-empty.png`, animations: "disabled" })
  await setColorScheme(page, "dark")
  await page.screenshot({ path: `${SHOTS}/editor-empty-dark.png`, animations: "disabled" })
  await setColorScheme(page, "light")

  // Blocks from the palette; the search narrows it.
  const palette = page.locator("#wf-palette")
  await page.locator("#wf-palette-search").fill(PREFIX)
  await expect(palette.locator("#palette-role-coder")).toBeHidden()
  const item = (name) => palette.locator("[data-palette]", { hasText: name })
  await addBlock(page, item(`${PREFIX} Coder`), { x: 200, y: 200 })
  await expect(page.locator("#wf-empty")).toBeHidden()
  await addBlock(page, item(`${PREFIX} Reviewer`), { x: 520, y: 200 })
  await addBlock(page, item(`${PREFIX} QA`), { x: 840, y: 200 })
  await page.locator("#wf-palette-search").fill("")
  await addBlock(page, palette.locator("#palette-human-any"), { x: 520, y: 520 })
  await addBlock(page, palette.locator("#palette-column-done"), { x: 840, y: 520 })
  await expect(page.locator("#wf-viewport .wf-node")).toHaveCount(5)

  const coder = block(page, `${PREFIX} Coder`)
  const reviewer = block(page, `${PREFIX} Reviewer`)
  const qa = block(page, `${PREFIX} QA`)
  const human = block(page, "Review")
  const done = block(page, "Done")
  await expect(coder.locator(".wf-start")).toBeVisible()

  // Renamed in place.
  await human.locator("[data-label]").dblclick()
  await page.locator("#wf-rename").fill("Approve")
  await page.keyboard.press("Enter")
  await expect(block(page, "Approve")).toBeVisible()

  // Dot to dot; the arrow opens in the inspector, where its condition is set.
  await connect(page, coder, "right", reviewer, "left")
  await expect(edges(page)).toHaveCount(1)
  await page.locator("#wf-inspector-condition").selectOption("done")
  await expect(page.locator("#wf-viewport .wf-edge-label", { hasText: "done" })).toBeVisible()

  // Dropped back on its own block: a loop, ×2 by default.
  await connect(page, reviewer, "top", reviewer)
  await expect(edges(page)).toHaveCount(2)
  await expect(page.locator("#wf-inspector-iterations")).toHaveValue("2")
  await expect(page.locator("#wf-viewport .wf-edge-label", { hasText: "×2" })).toBeVisible()

  // Onto the block's body: its nearest dot.
  await connect(page, reviewer, "right", qa)
  await expect(edges(page)).toHaveCount(3)

  // Rubber band around the three agents, then ⌘G.
  const canvas = await page.locator("#wf-viewport").boundingBox()
  await page.keyboard.down("Shift")
  await drag(page, { x: canvas.x + 60, y: canvas.y + 90 }, { x: canvas.x + 1000, y: canvas.y + 260 })
  await page.keyboard.up("Shift")
  await expect(page.locator("#wf-viewport .wf-node.is-selected")).toHaveCount(3)
  await page.keyboard.press("ControlOrMeta+g")
  const group = page.locator("#wf-viewport .wf-group")
  await expect(group).toHaveCount(1)
  await expect(group.locator(".wf-group-count")).toHaveText("3 blocks")

  // The group connects like a block: on to the human, who sends it back or finishes.
  await connect(page, group, "bottom", block(page, "Approve"), "top")
  await expect(edges(page)).toHaveCount(4)
  await connect(page, block(page, "Approve"), "right", done, "left")
  await expect(page.locator("#wf-inspector-panel")).toContainText("Approve → Done")
  await page.locator("#wf-inspector-condition").fill("accepted")
  await page.keyboard.press("Enter")
  await connect(page, block(page, "Approve"), "left", group, "left")
  await expect(page.locator("#wf-inspector-panel")).toContainText("Approve → Group 1")
  await page.locator("#wf-inspector-condition").fill("not accepted")
  await page.keyboard.press("Enter")
  await expect(edges(page)).toHaveCount(6)

  // The group starts the workflow (context menu).
  await group.locator("[data-group-header]").click({ button: "right" })
  await page.locator("#wf-menu-start").click()
  await expect(group.locator(".wf-start")).toBeVisible()
  await expect(coder.locator(".wf-start")).toHaveCount(0)
  await expect(problems(page)).toBeHidden()
  await expect(page.locator("#wf-dirty")).toBeVisible()

  await page.locator("#wf-fit").click()
  await page.screenshot({ path: `${SHOTS}/editor-graph.png`, animations: "disabled" })
  // The reviewer's own instructions (the fake bridge finds problems when told so); the
  // block shows it has some.
  await reviewer.locator("[data-label]").click()
  await page.locator("#wf-inspector-prompt").fill("Focus on security.\n[fake:findings]")
  await page.locator("#wf-inspector-label").focus()
  await expect(reviewer.locator("[data-prompt-mark]")).toHaveAttribute("title", /Focus on security/)
  await expect(qa.locator("[data-prompt-mark]")).toHaveCount(0)
  await page.screenshot({ path: `${SHOTS}/editor-inspector.png`, animations: "disabled" })
  await page.locator("#wf-viewport .wf-edge-label", { hasText: "×2" }).click()
  await expect(page.locator("#wf-inspector-iterations")).toBeVisible()
  await setColorScheme(page, "dark")
  await page.screenshot({ path: `${SHOTS}/editor-graph-dark.png`, animations: "disabled" })
  await setColorScheme(page, "light")

  await page.locator("#wf-save").click()
  await expect(page.locator("#wf-save")).toContainText("Saved")
  await expect(page.locator("#wf-dirty")).toBeHidden()

  // The server kept it all.
  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await expect(page.locator("#wf-viewport .wf-node")).toHaveCount(5)
  await expect(group).toHaveCount(1)
  await expect(group.locator(".wf-start")).toBeVisible()
  await expect(edges(page)).toHaveCount(6)
  for (const label of ["done", "×2", "accepted", "not accepted"]) {
    await expect(page.locator("#wf-viewport .wf-edge-label", { hasText: new RegExp(`^${label}$`) })).toBeVisible()
  }
  await expect(page.locator("#wf-no-problems")).toBeVisible()
  await reviewer.locator("[data-label]").click()
  await expect(page.locator("#wf-inspector-prompt")).toHaveValue("Focus on security.\n[fake:findings]")

  // Delete an arrow, undo, save.
  await page.locator("#wf-viewport .wf-edge-label", { hasText: /^accepted$/ }).click()
  await page.keyboard.press("Delete")
  await expect(edges(page)).toHaveCount(5)
  await expect(problems(page)).toBeVisible()
  await page.keyboard.press("ControlOrMeta+z")
  await expect(edges(page)).toHaveCount(6)
  await expect(page.locator("#wf-dirty")).toBeHidden()
  await page.keyboard.press("ControlOrMeta+s")
  await expect(page.locator("#wf-save")).toContainText("Saved")

  // A task with this workflow: the group's coder, the reviewer twice (its loop), QA, then
  // the human decides.
  const title = `${PREFIX} task ${Date.now()}`
  await visitConnected(page, "/tasks/new")
  await page.locator("#task-form input[name='form[title]']").fill(title)
  await page.locator("#task-form input[name='form[repository]']").fill("/repos/app")
  await page.locator("#task-form select[name='form[workflow_id]']").selectOption({ label: WORKFLOW })
  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()
  await expect(page.locator("#task-form")).toHaveCount(0)
  const card = page.locator("#board article", { hasText: title })
  const taskId = await card.getAttribute("data-task-id")
  await visitConnected(page, `/tasks/${taskId}/edit`)
  await page.locator("#task-drawer-status select").selectOption("todo")

  await visitConnected(page, `/tasks/${taskId}`)
  await expect(page.locator("#task-block")).toContainText("Approve", AGENT_WAIT)
  await page.locator("#tab-runs").click()
  const runs = page.locator("#runs li[id^='runs-']:not(#runs-empty)")
  await expect(runs).toHaveCount(4)
  await expect(runs.filter({ hasText: `${PREFIX} Reviewer` })).toHaveCount(2)
  await expect(runs.filter({ hasText: `${PREFIX} Coder` })).toHaveCount(1)
  await expect(runs.filter({ hasText: `${PREFIX} QA` })).toHaveCount(1)

  // Only the reviewer was told to find problems: its block's instructions reached both its
  // runs, and its second run (the loop) replaced the first's findings instead of repeating them.
  await page.locator("#tab-findings").click()
  await expect(page.locator("#finding-reviewer-f1")).toContainText("Greeting crashes on nil")
  await expect(page.locator("#finding-reviewer-f1-2")).toHaveCount(0)
  await expect(page.locator("[id^=finding-qa-]")).toHaveCount(0)
  await page.locator("#tab-runs").click()

  // "not accepted", with a note: back into the group, which runs its blocks again.
  await page.locator("#decision-comment").fill("Handle nil names too")
  await page.locator("[id^=decide-]", { hasText: "not accepted" }).click()
  await expect(page.locator("#task-block")).toContainText("Approve", AGENT_WAIT)
  await expect(runs).toHaveCount(8, AGENT_WAIT)
  await page.locator("#tab-activity").click()
  await expect(page.locator("#messages")).toContainText("Handle nil names too")

  await page.locator("[id^=decide-]", { hasText: /^\s*accepted\s*$/ }).click()
  await expect(page.locator("#task-status")).toHaveAttribute("data-status", "done")

  // The workflow can't be switched without asking once a task is on its way: covered by the
  // drawer's confirmation in board_live_test.exs; here the run is done.
  await cleanUp(page)
})
