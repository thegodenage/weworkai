const { test, expect } = require("@playwright/test")
const { removeTasks, visitConnected } = require("./helpers")

const TITLE_PREFIX = "E2E task "

test("board loads and LiveView connects", async ({ page }) => {
  await visitConnected(page, "/")
  await expect(page.locator("#board")).toBeVisible()
  await expect(page.locator("#column-backlog")).toBeAttached()
})

test("creating a task shows it on the board", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  const title = `${TITLE_PREFIX}${Date.now()}`

  await visitConnected(page, "/")
  await page.locator("#new-task").click()
  await page.locator("#task-form input[name='form[title]']").fill(title)
  await page.locator("#task-form input[name='form[repository]']").fill("/repos/app")
  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()

  await expect(page.locator("#task-form")).toHaveCount(0)
  const card = page.locator("#board article", { hasText: title })
  await expect(card).toBeVisible()
  await expect(page.locator("#board-column-backlog-count")).not.toHaveText("[00]")
  await page.screenshot({ path: "test-results/screens/board.png", animations: "disabled" })

  await card.getByRole("link").click()
  await expect(page.locator("#task-drawer-repository-input")).toHaveValue("/repos/app")
  await page.screenshot({ path: "test-results/screens/board-drawer.png", animations: "disabled" })

  await removeTasks(page, title)
})

test("employees page loads", async ({ page }) => {
  await visitConnected(page, "/employees")
  // The e2e database starts without employees, so the (empty) list is only attached.
  await expect(page.locator("#employees")).toBeAttached()
})

test("dashboard loads", async ({ page }) => {
  await visitConnected(page, "/dashboard")
  await expect(page.locator("#runs")).toBeAttached()
  await expect(page.locator("#tally-active")).toBeVisible()
})

test("the monospace face is served by the app itself", async ({ page }) => {
  const requests = []
  page.on("request", (request) => requests.push(request.url()))
  await visitConnected(page, "/dashboard")
  expect(await page.evaluate(() => document.fonts.load('1em "JetBrains Mono"').then((faces) => faces.length))).toBe(1)
  expect(requests.filter((url) => /fonts\.(googleapis|gstatic)\.com/.test(url))).toEqual([])
})

test("notifications page loads and the bell panel opens", async ({ page }) => {
  await visitConnected(page, "/notifications")
  await expect(page.locator("#inbox")).toBeAttached()
  await page.screenshot({ path: "test-results/screens/notifications-page.png", animations: "disabled" })
  await page.locator("#notification-bell-button").click()
  await expect(page.locator("#notification-panel")).toBeVisible()
  await page.keyboard.press("Escape")
  await expect(page.locator("#notification-panel")).toBeHidden()
})
