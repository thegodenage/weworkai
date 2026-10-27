const { test, expect } = require("@playwright/test")
const { AGENT_WAIT, visitConnected } = require("./helpers")
const { newWorkflow } = require("./editor_helpers")

// A block whose agent can't run is refused up front, naming both, and a failed run can be
// continued. Own connector, agents and workflows (prefix "SF", blocks naming its agents),
// so it runs beside the other specs.
const PREFIX = "SF"
const CONNECTOR = `${PREFIX} Bridge`
const UNCONFIGURED = `${PREFIX} New Planner`
const PLANNER = `${PREFIX} Planner`

test.use({ viewport: { width: 1440, height: 900 } })
test.setTimeout(120_000)

async function createAgent(page, name, { model }) {
  await visitConnected(page, "/employees/new")
  const form = page.locator("#employee-form")
  await form.locator("select[name='form[kind]']").selectOption("agent")
  await form.locator("input[name='form[name]']").fill(name)
  await form.locator("select[name='form[agent_role]']").selectOption("planner")
  await form.locator("select[name='form[connector_id]']").selectOption({ label: `${CONNECTOR} (Connected)` })
  await form.getByRole("button", { name: "Save" }).click()
  await expect(form).toHaveCount(0)
  if (!model) return

  // The list is paged by name and other specs add employees meanwhile, so look page by page.
  const configure = page.locator(`[aria-label="Configure ${name}"]`)
  for (let number = 1; (await configure.count()) === 0; number++) {
    await visitConnected(page, `/employees?page=${number}`)
  }
  await configure.click()
  await page.locator("#agent-form select[name='form[model]']").selectOption(model)
  await page.locator("#agent-form").getByRole("button", { name: "Save" }).click()
  await expect(page.locator("#agent-form")).toHaveCount(0)
}

// Leaves the repository as the form prefills it.
async function createTask(page, title, { workflow, description = "" } = {}) {
  await visitConnected(page, "/tasks/new")
  await page.locator("#task-form input[name='form[title]']").fill(title)
  await expect(page.locator("#task-form input[name='form[repository]']")).toHaveValue("~/Projects")
  await page.locator("#task-form-description-input").fill(description)
  if (workflow) await page.locator("#task-form select[name='form[workflow_id]']").selectOption({ label: workflow })
  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()
  await expect(page.locator("#task-form")).toHaveCount(0)
  return page.locator("#board article", { hasText: title })
}

async function setUp(page) {
  page.on("dialog", (dialog) => dialog.accept())

  await visitConnected(page, "/connectors/new")
  await page.locator("#connector-form input[name='form[name]']").fill(CONNECTOR)
  await page.locator("#connector-form").getByRole("button", { name: "Save" }).click()
  await page.locator(`[aria-label="Connect ${CONNECTOR}"]`).click()
  await expect(page.locator(`[aria-label="Connect ${CONNECTOR}"]`)).toHaveText("Reconnect")

  await createAgent(page, UNCONFIGURED, { model: null })
  await createAgent(page, PLANNER, { model: "claude-opus-5-5" })
}

test("an agent without a model is refused up front; a failed run continues", async ({ page }) => {
  await setUp(page)

  // A workflow whose only block names the agent without a model.
  const workflow = `${PREFIX} pinned`
  await newWorkflow(page, workflow)
  await page.locator("#wf-palette-search").fill(UNCONFIGURED)
  await page.locator("#wf-palette [data-palette]", { hasText: UNCONFIGURED }).click()
  await page.locator("#wf-save").click()
  await expect(page.locator("#wf-save")).toContainText(/^\s*Saved\s*$/)

  // Its tasks can't move to todo; the card stays put.
  const title = `${PREFIX} no model ${Date.now()}`
  const refused = await createTask(page, title, { workflow })

  await refused.getByRole("link").click()
  await page.locator("#task-drawer-status select").selectOption("todo")

  await expect(page.locator("#flash-error")).toContainText(
    `${UNCONFIGURED} can't run: ${UNCONFIGURED} has no model yet. Configure it on the Employees page.`,
  )
  await expect(page.locator("#column-backlog article", { hasText: title })).toBeVisible()
  await expect(page.locator("#column-todo article", { hasText: title })).toHaveCount(0)

  // A failed run can be continued from the task page. Its workflow names this spec's
  // planner: a role block would run whichever planner other specs made.
  const planned = `${PREFIX} planner`
  await newWorkflow(page, planned)
  await page.locator("#wf-palette-search").fill(PLANNER)
  await page.locator("#wf-palette [data-palette]", { hasText: PLANNER }).click()
  await expect(page.locator("#wf-viewport .wf-node")).toHaveCount(1)
  await page.locator("#wf-save").click()
  await expect(page.locator("#wf-save")).toContainText(/^\s*Saved\s*$/)

  const failing = `${PREFIX} failing ${Date.now()}`
  const card = await createTask(page, failing, { workflow: planned, description: "Plan it. [fake:fail]" })
  const taskId = await card.getAttribute("data-task-id")

  await card.getByRole("link").click()
  await page.locator("#task-drawer-status select").selectOption("todo")
  await expect(card.locator("[id^=needs-you-]")).toBeVisible(AGENT_WAIT)
  await expect(page.locator("#task-drawer-continue")).toContainText("Planner")

  await visitConnected(page, `/tasks/${taskId}?tab=activity`)
  await expect(page.locator("#messages")).toContainText("The agent run failed; see its log.")
  await expect(page.locator("#messages")).not.toContainText("Bread Crumbs")

  await page.locator("#continue-task").click()
  await expect(page.locator("#flash-info")).toContainText("Continued.")
  await expect(page.locator("#messages")).toContainText(`Continued by you → ${PLANNER}`)

  // The fake run fails again (its prompt still says so), so the task comes back to a human.
  await expect(page.locator("#messages")).toContainText("The agent run failed; see its log.", AGENT_WAIT)
  await expect(page.locator("#messages li", { hasText: "The agent run failed" })).toHaveCount(2, AGENT_WAIT)
})
