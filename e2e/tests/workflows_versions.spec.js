const { test, expect } = require("@playwright/test")
const { AGENT_WAIT, removeTasks, visitConnected } = require("./helpers")
const { block, center, drag } = require("./editor_helpers")

// Saving a workflow makes a version; a task keeps the one it started on until moved to the
// latest. Own connector, planner and workflow (prefix "WV"), so it runs beside the other
// specs; its plan notification would disturb task_review.spec.js's count, so it runs after
// (playwright.config.js matches "workflows").
const PREFIX = "WV"
const CONNECTOR = `${PREFIX} Bridge`
const PLANNER = `${PREFIX} Planner`
const WORKFLOW = `${PREFIX} versioned`

test.use({ viewport: { width: 1440, height: 900 } })
test.setTimeout(120_000)

async function setUp(page) {
  page.on("dialog", (dialog) => dialog.accept())

  await visitConnected(page, "/connectors/new")
  await page.locator("#connector-form input[name='form[name]']").fill(CONNECTOR)
  await page.locator("#connector-form").getByRole("button", { name: "Save" }).click()
  await page.locator(`[aria-label="Connect ${CONNECTOR}"]`).click()
  await expect(page.locator(`[aria-label="Connect ${CONNECTOR}"]`)).toHaveText("Reconnect")

  await visitConnected(page, "/employees/new")
  const form = page.locator("#employee-form")
  await form.locator("select[name='form[kind]']").selectOption("agent")
  await form.locator("input[name='form[name]']").fill(PLANNER)
  await form.locator("select[name='form[agent_role]']").selectOption("planner")
  await form.locator("select[name='form[connector_id]']").selectOption({ label: `${CONNECTOR} (Connected)` })
  await form.getByRole("button", { name: "Save" }).click()
  await page.locator(`[aria-label="Configure ${PLANNER}"]`).click()
  await page.locator("#agent-form select[name='form[model]']").selectOption("claude-opus-5-5")
  await page.locator("#agent-form").getByRole("button", { name: "Save" }).click()
  await expect(page.locator("#agent-form")).toHaveCount(0)
}

async function save(page) {
  await page.locator("#wf-save").click()
  await expect(page.locator("#wf-save")).toContainText(/^\s*Saved\s*$/)
}

test("a task keeps its workflow version until moved to the latest", async ({ page }) => {
  await setUp(page)

  // A copy of the default starts at v1; naming its planner block saves v2.
  await visitConnected(page, "/workflows/new")
  await page.locator("#workflow-form input[name='form[name]']").fill(WORKFLOW)
  await page.locator("#workflow-form select[name='form[source_id]']").selectOption({ label: "A copy of Default" })
  await page.locator("#workflow-form").getByRole("button", { name: "Save" }).click()
  await expect(page.locator("#workflow-name")).toHaveText(WORKFLOW)
  await expect(page.locator("#wf-version")).toHaveText("v1")
  const editor = page.url()

  await page.locator("#wf-viewport .wf-node", { hasText: "Planner" }).locator("[data-label]").click()
  await page.locator("#wf-inspector-who").selectOption({ label: `${PLANNER} · Planner` })
  await save(page)
  await expect(page.locator("#wf-version")).toHaveText("v2")

  // A task on it runs v2: its planner pauses on the plan's question.
  const title = `${PREFIX} task ${Date.now()}`
  await visitConnected(page, "/tasks/new")
  await page.locator("#task-form input[name='form[title]']").fill(title)
  await page.locator("#task-form input[name='form[repository]']").fill("/repos/app")
  await page.locator("#task-form select[name='form[workflow_id]']").selectOption({ label: WORKFLOW })
  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()
  const card = page.locator("#board article", { hasText: title })
  const taskId = await card.getAttribute("data-task-id")
  await visitConnected(page, `/tasks/${taskId}/edit`)
  await page.locator("#task-drawer-status select").selectOption("todo")
  await expect(card.locator("[id^=needs-you-]")).toBeVisible(AGENT_WAIT)

  await visitConnected(page, `/tasks/${taskId}`)
  await expect(page.locator("#task-workflow")).toContainText(WORKFLOW)
  await expect(page.locator("#task-workflow-version")).toHaveText("v2")
  await expect(page.locator("#task-upgrade-workflow")).toHaveCount(0)

  // Moving a block and saving makes v3; the history lists every save and the task on v2.
  await visitConnected(page, editor)
  const done = block(page, "Done")
  const from = await center(done.locator("[data-label]"))
  await drag(page, from, { x: from.x + 40, y: from.y + 40 })
  await save(page)
  await expect(page.locator("#wf-version")).toHaveText("v3")

  await page.locator("#wf-versions-toggle").click()
  await expect(page.locator("#wf-versions-list li")).toHaveCount(3)
  await expect(page.locator("#wf-version-3")).toHaveAttribute("data-current", "")
  await expect(page.locator("#wf-version-2-tasks")).toHaveText("1 task on it")
  await expect(page.locator("#wf-version-3-restore")).toHaveCount(0)
  await page.screenshot({ path: "test-results/screens/workflow-versions.png", animations: "disabled" })

  // The task page offers v3: its block is still there.
  await visitConnected(page, `/tasks/${taskId}`)
  await expect(page.locator("#task-upgrade-workflow")).toHaveText(/Move to v3/)
  await page.locator("#task-header").screenshot({ path: "test-results/screens/task-version.png" })
  await page.locator("#task-upgrade-workflow").click()
  await expect(page.locator("#task-workflow-version")).toHaveText("v3")
  await expect(page.locator("#task-upgrade-workflow")).toHaveCount(0)
  await expect(page.locator("#task-block")).toContainText(PLANNER)

  // Restoring v1 saves it as v4 and reopens the editor on it.
  await visitConnected(page, editor)
  await page.locator("#wf-versions-toggle").click()
  await page.locator("#wf-version-1-restore").click()
  await expect(page.locator("#wf-version")).toHaveText("v4")
  await expect(page.locator("#wf-viewport .wf-node .wf-node-label", { hasText: PLANNER })).toHaveCount(0)

  await removeTasks(page, title)
  await visitConnected(page, "/workflows")
  await page.locator(`[aria-label="Delete ${WORKFLOW}"]`).click()
  await expect(page.locator("#workflows li", { hasText: WORKFLOW })).toHaveCount(0)
})
