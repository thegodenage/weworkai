const { expect } = require("@playwright/test")

const AGENT_WAIT = { timeout: 60_000 }
const CONNECTOR = "E2E Bridge"

async function visitConnected(page, path) {
  await page.goto(path)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
}

// Deletes every board card whose title starts with the prefix (their notifications go with
// them), so a spec leaves no tasks for the ones after it. Needs a dialog handler that
// accepts the delete confirmation.
async function removeTasks(page, titlePrefix) {
  await visitConnected(page, "/")
  const cards = page.locator("#board article").filter({ hasText: titlePrefix })

  while ((await cards.count()) > 0) {
    const taskId = await cards.first().getAttribute("data-task-id")
    // A card with a plan opens the task page, so the drawer is opened by its URL.
    await visitConnected(page, `/tasks/${taskId}/edit`)
    await page.locator("#task-drawer-delete").click()
    await expect(page.locator(`#board article[data-task-id="${taskId}"]`)).toHaveCount(0)
  }
}

async function createConnector(page) {
  await visitConnected(page, "/connectors/new")
  await page.locator("#connector-form input[name='form[name]']").fill(CONNECTOR)
  await page.locator("#connector-form").getByRole("button", { name: "Save" }).click()
  await expect(page.locator("#connector-form")).toHaveCount(0)

  await page.locator(`[aria-label="Connect ${CONNECTOR}"]`).click()
  await expect(page.locator(`[aria-label="Connect ${CONNECTOR}"]`)).toHaveText("Reconnect")
}

async function createAgent(page, { name, role }) {
  await visitConnected(page, "/employees/new")
  const form = page.locator("#employee-form")
  await form.locator("select[name='form[kind]']").selectOption("agent")
  await form.locator("input[name='form[name]']").fill(name)
  await form.locator("select[name='form[agent_role]']").selectOption(role)
  await form.locator("select[name='form[connector_id]']").selectOption({ label: `${CONNECTOR} (Connected)` })
  await form.getByRole("button", { name: "Save" }).click()
  await expect(form).toHaveCount(0)

  await page.locator(`[aria-label="Configure ${name}"]`).click()
  await page.locator("#agent-form select[name='form[model]']").selectOption("claude-opus-5-5")
  await page.locator("#agent-form").getByRole("button", { name: "Save" }).click()
  await expect(page.locator("#agent-form")).toHaveCount(0)
}

// The page follows the system theme through a matchMedia listener, so wait for it to apply.
// Screenshots right after should pass `animations: "disabled"`: colours transition.
async function setColorScheme(page, colorScheme) {
  await page.emulateMedia({ colorScheme })
  await expect(page.locator("html")).toHaveAttribute("data-theme", colorScheme)
}

async function unreadCount(page) {
  const badge = page.locator("#notification-bell-count")
  if ((await badge.count()) === 0) return 0
  return Number((await badge.innerText()).replace("+", ""))
}

module.exports = {
  AGENT_WAIT,
  CONNECTOR,
  visitConnected,
  removeTasks,
  setColorScheme,
  createConnector,
  createAgent,
  unreadCount,
}
