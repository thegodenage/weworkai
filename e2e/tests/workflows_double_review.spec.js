const { test, expect } = require("@playwright/test")
const { AGENT_WAIT, removeTasks, visitConnected } = require("./helpers")

// "New from template" → Double review, opened in the editor, then a task runs it on
// bin/fake_claude_bridge up to Approve: the code and docker reviewers run twice each. Own
// connector, agents and workflow (prefix "DR"); its plan and ready-to-merge notifications
// would disturb task_review.spec.js's count, so it runs after (playwright.config.js).
const PREFIX = "DR"
const CONNECTOR = `${PREFIX} Bridge`
const AGENTS = [
  [`${PREFIX} Planner`, "planner"],
  [`${PREFIX} Coder`, "coder"],
  [`${PREFIX} Reviewer`, "reviewer"],
  [`${PREFIX} QA`, "qa"],
]
const WORKFLOW = `${PREFIX} twice`

test.use({ viewport: { width: 1440, height: 900 } })
test.setTimeout(180_000)

async function setUp(page) {
  page.on("dialog", (dialog) => dialog.accept())

  await visitConnected(page, "/connectors/new")
  await page.locator("#connector-form input[name='form[name]']").fill(CONNECTOR)
  await page.locator("#connector-form").getByRole("button", { name: "Save" }).click()
  await page.locator(`[aria-label="Connect ${CONNECTOR}"]`).click()
  await expect(page.locator(`[aria-label="Connect ${CONNECTOR}"]`)).toHaveText("Reconnect")

  for (const [name, role] of AGENTS) {
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

test("a workflow from the Double review template reviews the code twice", async ({ page }) => {
  await setUp(page)

  await visitConnected(page, "/workflows")
  await page.locator("#new-from-template").click()
  await expect(page.locator("#template-choice")).toBeVisible()
  await page.locator("#workflow-form input[name='form[name]']").fill(WORKFLOW)
  await page.locator("#template-double_review").click()
  await expect(page.locator("#template-double_review-input")).toBeChecked()
  await page.screenshot({ path: "test-results/screens/new-from-template.png", animations: "disabled" })
  await page.locator("#workflow-form").getByRole("button", { name: "Save" }).click()

  await expect(page.locator("#workflow-name")).toHaveText(WORKFLOW)
  await expect(page.locator("#wf-viewport .wf-node")).toHaveCount(7)
  await expect(page.locator("#wf-viewport .wf-group", { hasText: "Full review" })).toContainText("2 blocks")
  await expect(page.locator("#wf-viewport .wf-edge-label", { hasText: "clean · ×2" })).toBeVisible()
  await expect(page.locator("#wf-viewport .wf-edge-label", { hasText: "findings · max 3" })).toBeVisible()
  await expect(page.locator("#wf-problem-count")).toBeHidden()
  await page.screenshot({ path: "test-results/screens/double-review.png" })

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
  await expect(card.locator("[id^=needs-you-]")).toBeVisible(AGENT_WAIT)

  // The fake plan asks a question; approving it anyway goes on to the coder.
  await visitConnected(page, `/tasks/${taskId}?tab=plan`)
  const coderSelect = page.locator("#approve-coder")
  if ((await coderSelect.count()) > 0) await coderSelect.selectOption({ label: `${PREFIX} Coder` })
  await page.locator("#approve-plan").click()
  await expect(page.locator("#task-branch")).toContainText("weworkai/")

  await expect(page.locator("#ready-to-merge")).toBeVisible({ timeout: 120_000 })
  await expect(page.locator("#task-block")).toContainText("Approve")

  await page.locator("#tab-runs").click()
  const runs = (stage) => page.locator(`#runs li[data-stage=${stage}]`)
  await expect(runs("code_review")).toHaveCount(2)
  await expect(runs("qa")).toHaveCount(2)
  await expect(runs("coding")).toHaveCount(1)
  await expect(runs("planning")).toHaveCount(1)
  await page.screenshot({ path: "test-results/screens/double-review-runs.png", fullPage: true })

  await removeTasks(page, title)
  await visitConnected(page, "/workflows")
  await page.locator(`[aria-label="Delete ${WORKFLOW}"]`).click()
  await expect(page.locator(`[aria-label="Delete ${WORKFLOW}"]`)).toHaveCount(0)
})
