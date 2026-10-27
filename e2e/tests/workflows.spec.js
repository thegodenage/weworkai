const { test, expect } = require("@playwright/test")
const { AGENT_WAIT, removeTasks, visitConnected } = require("./helpers")

// A workflow duplicated from the default runs a task like the default does. Own connector,
// planner and workflow (prefix "WF"; its planner block names that planner), so it runs
// beside the other specs; the copy goes to
// the end of the list, so the default stays the default for them. Its plan notification
// would disturb task_review.spec.js's count, so it runs after (playwright.config.js).
const PREFIX = "WF"
const CONNECTOR = `${PREFIX} Bridge`
const PLANNER = `${PREFIX} Planner`
const WORKFLOW = `${PREFIX} copy`

test.use({ viewport: { width: 1440, height: 900 } })
test.setTimeout(120_000)

async function removeWorkflows(page) {
  await visitConnected(page, "/workflows")
  const removeButtons = page.locator(`[aria-label^="Delete ${WORKFLOW}"]`)

  for (let count = await removeButtons.count(); count > 0; count--) {
    await removeButtons.first().click()
    await expect(removeButtons).toHaveCount(count - 1)
  }
}

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

test("a task runs a workflow duplicated from the default", async ({ page }) => {
  await setUp(page)

  // The sidebar leads to the list, where the default comes first.
  await visitConnected(page, "/")
  await page.locator("nav a[href='/workflows']").click()
  await expect(page).toHaveURL(/\/workflows$/)
  await expect(page.locator("#workflows li").first().locator("[id$=-default]")).toBeVisible()

  // A copy opens in the editor with the default's blocks and arrows.
  await page.locator("#new-workflow").click()
  await page.locator("#workflow-form input[name='form[name]']").fill(WORKFLOW)
  await page.locator("#workflow-form select[name='form[source_id]']").selectOption({ label: "A copy of Default" })
  await page.locator("#workflow-form").getByRole("button", { name: "Save" }).click()
  await expect(page.locator("#workflow-name")).toHaveText(WORKFLOW)
  await expect(page.locator("#wf-viewport .wf-node")).toHaveCount(7)
  await expect(page.locator("#wf-viewport .wf-node", { hasText: "Planner" }).locator(".wf-start")).toBeVisible()
  await expect(page.locator("#wf-viewport .wf-edge-label", { hasText: "findings · max 3" })).toBeVisible()
  await page.screenshot({ path: "test-results/screens/workflow.png", fullPage: true })

  // Its planner block runs this spec's own planner, not whichever planner other specs made.
  await page.locator("#wf-viewport .wf-node", { hasText: "Planner" }).locator("[data-label]").click()
  await page.locator("#wf-inspector-who").selectOption({ label: `${PLANNER} · Planner` })
  await expect(page.locator("#wf-viewport .wf-node .wf-node-label", { hasText: PLANNER })).toBeVisible()
  await page.locator("#wf-save").click()
  await expect(page.locator("#wf-save")).toContainText(/^\s*Saved\s*$/)

  await page.locator("#back-to-workflows").click()
  const row = page.locator("#workflows li", { hasText: WORKFLOW })
  await expect(row).toContainText("7 blocks")
  await expect(row.locator("[id$=-default]")).toHaveCount(0)
  await page.screenshot({ path: "test-results/screens/workflows.png", fullPage: true })

  // A task created with the copy runs its planner block.
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
  await expect(page.locator("#task-drawer-workflow option:checked")).toHaveText(WORKFLOW)
  await page.locator("#task-drawer-status select").selectOption("todo")
  await expect(card.locator(`#task-${taskId}-block`)).toHaveText(PLANNER)
  await expect(card.locator("[id^=needs-you-]")).toBeVisible(AGENT_WAIT)

  await visitConnected(page, `/tasks/${taskId}`)
  await expect(page.locator("#task-block")).toContainText(PLANNER)
  await expect(page.locator("#plan-summary")).toBeVisible()
  await page.locator("#tab-runs").click()
  await expect(page.locator("#runs li[id^='runs-']:not(#runs-empty)", { hasText: PLANNER })).toHaveCount(1)

  // The copy can't go while the task runs it.
  await visitConnected(page, "/workflows")
  await page.locator(`[aria-label="Delete ${WORKFLOW}"]`).click()
  await expect(page.locator("#flash-error")).toContainText("1 task still use this workflow")

  await removeTasks(page, title)
  await removeWorkflows(page)
})
