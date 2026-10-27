const { test, expect } = require("@playwright/test")
const { AGENT_WAIT, removeTasks, setColorScheme, visitConnected } = require("./helpers")

// Budgets with a hard stop, driven by bin/fake_claude_bridge's fixed usage: a planner run
// costs $0.0912. A $0.05 task cap lets the first plan through, then refuses the planner's
// revision and hands the task to a human; a raised cap and Continue let it run.
// Own connector and planner (prefix "BG"); whichever runnable planner takes the task, the
// fake bridge reports the same.
const PREFIX = "BG"
const CONNECTOR = `${PREFIX} Bridge`
const PLANNER = `${PREFIX} Planner`

test.use({ viewport: { width: 1440, height: 900 } })
test.setTimeout(150_000)

async function configureLink(page) {
  // The list is paged by name and other specs add employees meanwhile, so look page by page.
  const configure = page.locator(`[aria-label="Configure ${PLANNER}"]`)
  for (let number = 1; (await configure.count()) === 0; number++) {
    await visitConnected(page, `/employees?page=${number}`)
  }
  return configure
}

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
  await (await configureLink(page)).click()
  await page.locator("#agent-form select[name='form[model]']").selectOption("claude-opus-5-5")
  await page.locator("#agent-form input[name='form[budget_usd]']").fill("25")
  await page.locator("#agent-form select[name='form[budget_period]']").selectOption("week")
  await page.locator("#agent-form").getByRole("button", { name: "Save" }).click()
  await expect(page.locator("#agent-form")).toHaveCount(0)
}

async function setTaskBudget(page, usd) {
  await page.locator("#task-budget-edit").click()
  await page.locator("#task-budget-input").fill(usd)
  await page.locator("#task-budget-save").click()
  await expect(page.locator("#task-budget-form")).toHaveCount(0)
}

test("a spent task budget stops the next run until a human raises it", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await setUp(page)

  const row = (await configureLink(page)).locator("xpath=ancestor::tr")
  await expect(row.locator("[id^=budget-]")).toContainText("/ $25.00")
  await row.screenshot({ path: "test-results/screens/budget-employee-row.png" })

  const title = `${PREFIX} Budget ${Date.now()}`
  await visitConnected(page, "/tasks/new")
  await page.locator("#task-form input[name='form[title]']").fill(title)
  await page.locator("#task-form input[name='form[repository]']").fill("/repos/app")
  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()
  await expect(page.locator("#task-form")).toHaveCount(0)
  const taskId = await page.locator("#board article", { hasText: title }).getAttribute("data-task-id")

  await visitConnected(page, `/tasks/${taskId}`)
  await setTaskBudget(page, "0.05")
  await expect(page.locator("#task-budget-meter")).toHaveAttribute("data-mark", "ok")
  await expect(page.locator("#task-budget-meter")).toContainText("$0 / $0.0500")

  await visitConnected(page, `/tasks/${taskId}/edit`)
  await page.locator("#task-drawer-status select").selectOption("todo")
  await visitConnected(page, `/tasks/${taskId}`)
  await expect(page.locator("#plan-summary")).toBeVisible(AGENT_WAIT)

  // The first run was allowed and took the task past its cap.
  const meter = page.locator("#task-budget-meter")
  await expect(meter).toHaveAttribute("data-mark", "reached")
  await expect(meter).toContainText("$0.0912 / $0.0500")
  await expect(meter).toContainText("182%")
  await page.locator("#task-header").screenshot({ path: "test-results/screens/budget-reached-header.png" })

  // The planner's revision is refused before it starts: the task waits for a human, who is told why.
  await page.locator("#comment-body").fill("Shorter, please.")
  await page.locator("#request-changes").click()
  await expect(page.locator("#task-needs-you")).toBeVisible(AGENT_WAIT)
  await page.locator("#tab-activity").click()
  await expect(page.locator("#messages")).toContainText("can't start: Budget reached.", AGENT_WAIT)
  await expect(page.locator("#messages")).toContainText("This task has spent $0.0912 of its $0.0500 budget.")
  await page.screenshot({ path: "test-results/screens/budget-refused.png", fullPage: true })

  await page.locator("#notification-bell-button").click()
  await expect(page.locator("#notification-list")).toContainText(`Budget reached: ${title}`)
  await page.screenshot({ path: "test-results/screens/budget-notification.png", animations: "disabled" })
  await page.locator("#notification-bell-button").click()
  await expect(page.locator("#notification-panel")).toBeHidden()

  // Raised, then Continue: the planner revises the plan.
  await setTaskBudget(page, "1")
  await expect(meter).toHaveAttribute("data-mark", "ok")
  await expect(meter).toContainText("$0.0912 / $1.00")
  await page.locator("#continue-task").click()
  await page.locator("#tab-plan").click()
  await expect(page.locator("#plan-summary")).toContainText("Revised plan", AGENT_WAIT)
  await expect(meter).toContainText("$0.1824 / $1.00")
  await page.locator("#task-header").screenshot({ path: "test-results/screens/budget-raised-header.png" })
  await setColorScheme(page, "dark")
  await page.locator("#task-header").screenshot({
    path: "test-results/screens/budget-raised-header-dark.png",
    animations: "disabled",
  })
  await setColorScheme(page, "light")

  // The crossing is a point on the audit timeline.
  await visitConnected(page, `/audit/${taskId}`)
  await expect(page.locator("[id^=gantt-point-][data-kind=budget]")).toHaveCount(1)
  await page.screenshot({ path: "test-results/screens/budget-audit.png", fullPage: true })

  await removeTasks(page, title)
})
