const { test, expect } = require("@playwright/test")
const { AGENT_WAIT, removeTasks, setColorScheme, visitConnected } = require("./helpers")

// What agent runs used, as bin/fake_claude_bridge reports it: a planner run is 50.6k tokens and
// $0.0912 (its USAGE table), shown on the task, its runs, the run's page and the audit page.
// Own connector and planner (prefix "CL"); whichever runnable planner takes the task, the
// fake bridge reports the same.
const PREFIX = "CL"
const CONNECTOR = `${PREFIX} Bridge`
const PLANNER = `${PREFIX} Planner`

test.use({ viewport: { width: 1440, height: 900 } })
test.setTimeout(120_000)

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

test("a run's tokens and cost add up on its task and per agent", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await setUp(page)

  const title = `${PREFIX} Ledger ${Date.now()}`
  await visitConnected(page, "/tasks/new")
  await page.locator("#task-form input[name='form[title]']").fill(title)
  await page.locator("#task-form input[name='form[repository]']").fill("/repos/app")
  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()
  await expect(page.locator("#task-form")).toHaveCount(0)
  const taskId = await page.locator("#board article", { hasText: title }).getAttribute("data-task-id")

  await visitConnected(page, `/tasks/${taskId}/edit`)
  await page.locator("#task-drawer-status select").selectOption("todo")
  await visitConnected(page, `/tasks/${taskId}`)
  await expect(page.locator("#plan-summary")).toBeVisible(AGENT_WAIT)

  const usage = page.locator("#task-usage")
  await expect(usage).toHaveText("50.6k tok · $0.0912")
  await expect(usage.locator("[title]")).toHaveAttribute("title", /input 4\.2k · output 1\.9k/)
  await page.locator("#task-header").screenshot({ path: "test-results/screens/ledger-task-header.png" })

  await page.locator("#tab-runs").click()
  const run = page.locator("#runs li[id^='runs-']:not(#runs-empty)")
  await expect(run.locator("[id$=-usage]")).toHaveText("50.6k tok · $0.0912")
  await page.locator("#runs-panel").screenshot({ path: "test-results/screens/ledger-runs.png" })

  await run.getByRole("link", { name: "Log" }).click()
  await expect(page.locator("#run-usage")).toContainText("50.6k tok · $0.0912")
  await expect(page.locator("#run-usage")).toContainText("6 turns")

  await visitConnected(page, `/audit/${taskId}`)
  await expect(page.locator("#audit-stat-tokens")).toContainText("50.6k")
  await expect(page.locator("#audit-stat-cost")).toContainText("$0.0912")
  await page.locator("[id^=gantt-bar-]").first().click()
  await expect(page.locator("#audit-bar-usage")).toContainText("$0.0912")
  await page.screenshot({ path: "test-results/screens/ledger-audit-task.png", fullPage: true })

  await visitConnected(page, "/audit")
  await expect(page.locator("#audit-spend tbody tr").first()).toBeVisible()
  await page.screenshot({ path: "test-results/screens/ledger-audit-spend.png", fullPage: true })
  await setColorScheme(page, "dark")
  await page.screenshot({
    path: "test-results/screens/ledger-audit-spend-dark.png",
    fullPage: true,
    animations: "disabled",
  })
  await setColorScheme(page, "light")

  await removeTasks(page, title)
})
