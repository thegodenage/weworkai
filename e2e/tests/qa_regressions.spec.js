const { test, expect } = require("@playwright/test")
const { AGENT_WAIT, removeTasks, visitConnected } = require("./helpers")

// Regressions found by QA: announcements on the task page, notification read state across
// tabs, long titles in toasts and the task toolbar at phone width. Own connector and
// planner (prefix "QA"), so it runs beside task_review.spec.js.
const PREFIX = "QA"
const CONNECTOR = `${PREFIX} Bridge`
const PLANNER = `${PREFIX} Planner`

test.setTimeout(120_000)

async function setUp(page) {
  await visitConnected(page, "/connectors/new")
  await page.locator("#connector-form input[name='form[name]']").fill(CONNECTOR)
  await page.locator("#connector-form").getByRole("button", { name: "Save" }).click()
  await page.locator(`[aria-label="Connect ${CONNECTOR}"]`).click()
  await expect(page.locator(`[aria-label="Connect ${CONNECTOR}"]`)).toHaveText("Reconnect")

  // Two coders, so the toolbar shows its coder picker.
  for (const [name, role] of [[PLANNER, "planner"], [`${PREFIX} Coder 1`, "coder"], [`${PREFIX} Coder 2`, "coder"]]) {
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

async function createPlannedTask(page, title) {
  await visitConnected(page, "/tasks/new")
  await page.locator("#task-form input[name='form[title]']").fill(title)
  await page.locator("#task-form input[name='form[repository]']").fill("/repos/app")
  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()
  await expect(page.locator("#task-form")).toHaveCount(0)
  return page.locator("#board article", { hasText: title }).getAttribute("data-task-id")
}

test("the task page, the bell and phone widths after a plan arrives", async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } })
  const page = await context.newPage()
  page.on("dialog", (dialog) => dialog.accept())
  await setUp(page)

  // One unbroken word, as long as a title may be.
  const title = `${PREFIX} ${"w".repeat(190)}`
  const taskId = await createPlannedTask(page, title)
  await visitConnected(page, `/tasks/${taskId}/edit`)
  await page.locator("#task-drawer-status select").selectOption("todo")
  await visitConnected(page, `/tasks/${taskId}?tab=plan`)

  // The plan is announced once: by its toast, not by a flash as well.
  const toast = page.locator("#notification-toasts [data-notification-id]", {
    hasText: `Plan ready: ${PREFIX} w`,
  })
  await expect(toast).toBeVisible(AGENT_WAIT)
  await expect(page.locator("#plan-summary")).toBeVisible()
  await expect(page.locator("#flash-info")).toHaveCount(0)

  // The long title wraps inside the toast.
  const overflow = await toast.evaluate((el) => el.scrollWidth - el.clientWidth)
  expect(overflow).toBeLessThanOrEqual(0)

  // Reading in one tab clears it in the other (task_review.spec.js may notify meanwhile).
  const other = await context.newPage()
  await visitConnected(other, "/")
  const unreadPlan = other.locator("#notification-list a[data-unread]", {
    hasText: `Plan ready: ${PREFIX} w`,
  })
  await expect(unreadPlan).toHaveCount(1)
  // Only this spec's notification is read: "Mark all read" would race task_review.spec.js.
  await page.locator("#notification-bell-button").click()
  await page.locator("#notification-list a", { hasText: `Plan ready: ${PREFIX} w` }).click()
  await expect(unreadPlan).toHaveCount(0)

  // The toolbar (coder picker + approve) fits a phone screen.
  const phone = await browser.newPage({ viewport: { width: 375, height: 812 } })
  await visitConnected(phone, `/tasks/${taskId}`)
  await expect(phone.locator("#approve-coder")).toBeVisible()
  const width = await phone.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth])
  expect(width[0]).toBeLessThanOrEqual(width[1])
  await phone.screenshot({ path: "test-results/screens/task-phone.png", fullPage: true })

  // The request-changes panel stays out of the way on a phone until opened.
  await phone.locator("#step-s1").scrollIntoViewIfNeeded()
  await phone.screenshot({ path: "test-results/screens/task-phone-viewport.png", animations: "disabled" })
  const panel = await phone.locator("#review-panel").boundingBox()
  expect(panel.height).toBeLessThan(812 * 0.12)
  await expect(phone.locator("#comment-body")).toBeHidden()
  await phone.locator("#review-panel-toggle").click()
  await expect(phone.locator("#comment-body")).toBeVisible()
  await phone.screenshot({ path: "test-results/screens/task-phone-panel-open.png", animations: "disabled" })

  await removeTasks(page, title)
})
