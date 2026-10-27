const { test, expect } = require("@playwright/test")
const { AGENT_WAIT, removeTasks, setColorScheme, visitConnected } = require("./helpers")

// Asking an agent about a task, against bin/fake_claude_bridge: the answer lands in the Ask
// thread while the task stays where it is, also while its own planner works. Own connector
// and planner (prefix "AK"); runs after the other specs, whose planners (any that can run
// plans and answers) are all set up by then.
const PREFIX = "AK"
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
  await page.locator(`[aria-label="Configure ${PLANNER}"]`).click()
  await page.locator("#agent-form select[name='form[model]']").selectOption("claude-opus-5-5")
  await page.locator("#agent-form").getByRole("button", { name: "Save" }).click()
  await expect(page.locator("#agent-form")).toHaveCount(0)
}

async function createTask(page, title, description) {
  await visitConnected(page, "/tasks/new")
  await page.locator("#task-form input[name='form[title]']").fill(title)
  if (description) await page.locator("#task-form-description-input").fill(description)
  await page.locator("#task-form input[name='form[repository]']").fill("/repos/app")
  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()
  await expect(page.locator("#task-form")).toHaveCount(0)
  return page.locator("#board article", { hasText: title }).getAttribute("data-task-id")
}

async function ask(page, question) {
  await page.locator("#ask-body").fill(question)
  await page.locator("#ask-submit").click()
  await expect(page.locator("#ask-thread li", { hasText: question }).first()).toBeVisible()
}

test("a question about a task is answered beside its workflow", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await setUp(page)

  const title = `${PREFIX} Hello ${Date.now()}`
  // The first plan takes a while ([fake:slow]), so the board can be looked at meanwhile.
  const taskId = await createTask(page, title, "Greet users by name. [fake:slow]")
  await visitConnected(page, `/tasks/${taskId}/edit`)
  await page.locator("#task-drawer-status select").selectOption("todo")
  await page.locator("#task-drawer-close").click()
  const working = page.locator(`#task-${taskId}-working`)
  await expect(working).toBeVisible()
  await expect(working).toHaveAttribute("data-state", "running", AGENT_WAIT)
  await expect(working).toHaveAttribute("data-stage", "planning")
  await expect(page.locator(`#task-${taskId}-working-elapsed`)).toHaveText(/^· \d/)
  const column = page.locator("section[data-status=in_progress]")
  await column.screenshot({ path: "test-results/screens/board-working.png" })
  await setColorScheme(page, "dark")
  await column.screenshot({ path: "test-results/screens/board-working-dark.png", animations: "disabled" })
  await setColorScheme(page, "light")

  await visitConnected(page, `/tasks/${taskId}`)
  await expect(page.locator("#task-working")).toHaveAttribute("data-stage", "planning")
  await expect(page.locator("#task-working")).toHaveAttribute("data-state", "running")
  await page.screenshot({ path: "test-results/screens/task-working.png" })
  await expect(page.locator("#plan-summary")).toBeVisible(AGENT_WAIT)
  await expect(page.locator("#task-working")).toHaveCount(0)

  await page.locator("#tab-ask").click()
  await expect(page.locator("#ask-thread-empty")).toBeVisible()
  await expect(page.locator("#ask-hint")).toContainText("planner's conversation")
  await page.screenshot({ path: "test-results/screens/ask-empty.png", fullPage: true })

  await ask(page, "Why does the plan need two steps?\nKeep it short.")
  await expect(page.locator("#ask-pending")).toBeVisible()
  await expect(page.locator("#task-working[data-stage=ask]")).toBeVisible()
  await page.screenshot({ path: "test-results/screens/ask-pending.png", fullPage: true })

  await expect(page.locator("#ask-thread")).toContainText(
    "Fake answer to: Why does the plan need two steps?",
    AGENT_WAIT,
  )
  await expect(page.locator("#ask-pending")).toHaveCount(0)
  await expect(
    page.locator("#notification-toasts [data-notification-id]", { hasText: `Answer ready: ${title}` }),
  ).toBeVisible()
  await expect(page.locator("#task-status[data-status=await_human_supervision]")).toBeVisible()
  await expect(page.locator("#task-stage[data-stage=planning]")).toBeVisible()
  await page.screenshot({ path: "test-results/screens/ask-answered.png", fullPage: true })
  await setColorScheme(page, "dark")
  await page.screenshot({ path: "test-results/screens/ask-answered-dark.png", fullPage: true, animations: "disabled" })
  await setColorScheme(page, "light")

  // While the planner revises the plan, a question runs beside it; both finish.
  await page.locator("#tab-plan").click()
  await page.locator("#comment-body").fill("Keep it English only.")
  await page.locator("#request-changes").click()
  await expect(page.locator("#agent-working")).toBeVisible()
  await page.locator("#tab-ask").click()
  await ask(page, "Are you still planning?")
  await expect(page.locator("#ask-thread")).toContainText("Fake answer to: Are you still planning?", AGENT_WAIT)
  await page.locator("#tab-plan").click()
  await expect(page.locator("#plan-summary")).toContainText("Revised plan", AGENT_WAIT)

  await page.locator("#tab-activity").click()
  await expect(page.locator("#messages")).toContainText("Fake answer to: Are you still planning?")

  // Never coded, so there is nothing for a reviewer to review.
  await visitConnected(page, `/tasks/${taskId}/edit`)
  await page.locator("#task-drawer-status select").selectOption("review")
  await expect(page.locator("#flash-error")).toContainText("Nothing to review yet: no code changes")
  await expect(page.locator(`#column-review article[data-task-id="${taskId}"]`)).toHaveCount(0)

  await removeTasks(page, `${PREFIX} `)
})
