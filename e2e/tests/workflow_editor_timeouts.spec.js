const { test, expect } = require("@playwright/test")
const { visitConnected, removeTasks } = require("./helpers")
const { block, newWorkflow } = require("./editor_helpers")

// An agent block's own timeouts: set in the editor, kept after a reload, and a run that goes
// silent past them ([fake:hang]) is stopped, logged on the task and retried. Own connector,
// agent and workflow (prefix "RT"); its task is deleted at the end so no retry outlives it.
const PREFIX = "RT"
const CONNECTOR = `${PREFIX} Bridge`
const PLANNER = `${PREFIX} Planner`
const WORKFLOW = `${PREFIX} timeouts`
const SHOTS = "test-results/screens"

test.use({ viewport: { width: 1440, height: 900 } })
test.setTimeout(240_000)

test.afterAll(async ({ browser }) => {
  const page = await browser.newPage()
  page.on("dialog", (dialog) => dialog.accept())
  await removeTasks(page, PREFIX)
  await page.close()
})

async function setUp(page) {
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
  await expect(form).toHaveCount(0)

  // The list is paged by name and other specs add employees meanwhile, so look page by page.
  const configure = page.locator(`[aria-label="Configure ${PLANNER}"]`)
  for (let number = 1; (await configure.count()) === 0; number++) {
    await visitConnected(page, `/employees?page=${number}`)
  }
  await configure.click()
  await page.locator("#agent-form select[name='form[model]']").selectOption("claude-opus-5-5")
  await page.locator("#agent-form").getByRole("button", { name: "Save" }).click()
  await expect(page.locator("#agent-form")).toHaveCount(0)
}

test("a block's stall timeout stops a silent run and retries it", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await setUp(page)

  await newWorkflow(page, WORKFLOW)
  await page.locator("#wf-palette-search").fill(PLANNER)
  await page.locator("#wf-palette [data-palette]", { hasText: PLANNER }).click()
  const stall = page.locator("#wf-inspector-stall-timeout-minutes")
  await expect(stall).toHaveAttribute("placeholder", "15")
  await expect(page.locator("#wf-inspector-turn-timeout-minutes")).toHaveAttribute("placeholder", "120")
  await stall.fill("1")
  await stall.blur()
  await page.locator("#wf-save").click()
  await expect(page.locator("#wf-save")).toContainText(/^\s*Saved\s*$/)

  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await block(page, PLANNER).locator("[data-label]").click()
  await expect(stall).toHaveValue("1")
  await expect(page.locator("#wf-inspector-turn-timeout-minutes")).toHaveValue("")
  await page.locator("#wf-inspector-timeouts").screenshot({ path: `${SHOTS}/editor-timeouts.png`, animations: "disabled" })

  const title = `${PREFIX} hangs ${Date.now()}`
  await visitConnected(page, "/tasks/new")
  await page.locator("#task-form input[name='form[title]']").fill(title)
  await page.locator("#task-form-description-input").fill("Plan it. [fake:hang]")
  await page.locator("#task-form select[name='form[workflow_id]']").selectOption({ label: WORKFLOW })
  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()
  await expect(page.locator("#task-form")).toHaveCount(0)
  const card = page.locator("#board article", { hasText: title })
  const taskId = await card.getAttribute("data-task-id")
  await card.getByRole("link").click()
  await page.locator("#task-drawer-status select").selectOption("todo")

  // The fake run writes nothing after it starts, so a minute later it is stopped.
  await visitConnected(page, `/tasks/${taskId}?tab=runs`)
  await expect(async () => {
    await page.reload()
    await expect(page.locator("#runs [id$=-error]")).toContainText("The agent wrote nothing for 1 minute", {
      timeout: 1_000,
    })
  }).toPass({ timeout: 120_000, intervals: [3_000] })
  await page.locator("#runs-panel").screenshot({ path: `${SHOTS}/runs-stalled.png`, animations: "disabled" })

  await visitConnected(page, `/audit/${taskId}`)
  const point = page.locator("[id^=gantt-point-][data-kind=stalled]")
  await expect(point).toHaveCount(1)
  await expect(point).toHaveAttribute("title", /The planner stalled: silent for 1m/)
})
