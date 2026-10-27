const { test, expect } = require("@playwright/test")
const { removeTasks, visitConnected } = require("./helpers")

test("the folder picker fills the repository and the drawer saves it", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  const title = `E2E picker ${Date.now()}`

  await visitConnected(page, "/")
  await page.locator("#new-task").click()
  await page.locator("#task-form input[name='form[title]']").fill(title)

  await page.locator("#task-form-repository-browse").click()
  const folders = page.locator("#task-form-repository-folders")
  await expect(folders).toContainText("weworkai")
  await folders.locator("li", { hasText: "weworkai" }).hover()
  await page.locator("#task-form-repository-panel").scrollIntoViewIfNeeded()
  await page.screenshot({ path: "test-results/screens/folder-picker.png", animations: "disabled" })
  await folders.locator("[data-choose='~/Projects/weworkai']").click()
  await expect(page.locator("#task-form-repository-panel")).toHaveCount(0)
  await expect(page.locator("#task-form-repository-input")).toHaveValue("~/Projects/weworkai")

  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()
  const card = page.locator("#board article", { hasText: title })
  const taskId = await card.getAttribute("data-task-id")
  await card.getByRole("link").click()
  await expect(page.locator("#task-drawer-repository-input")).toHaveValue("~/Projects/weworkai")

  // An open folder list takes Escape for itself; the drawer stays.
  await page.locator("#task-drawer-repository-browse").click()
  await expect(page.locator("#task-drawer-repository-panel")).toBeVisible()
  await page.keyboard.press("Escape")
  await expect(page.locator("#task-drawer-repository-panel")).toHaveCount(0)
  await expect(page.locator("#task-drawer")).toBeVisible()

  await page.locator("#task-drawer-repository-browse").click()
  await page.locator("#task-drawer-repository-up").click()
  await expect(page.locator("#task-drawer-repository-panel code")).toHaveText("~/Projects")
  await page.locator("#task-drawer-repository-choose").click()
  await expect(page.locator("#task-drawer-repository-input")).toHaveValue("~/Projects")
  // Escape closes the drawer (back to the board); the chosen folder was saved on the way.
  await page.keyboard.press("Escape")
  await expect(page.locator("#task-drawer")).toHaveCount(0)
  await expect(page).toHaveURL(/\/$/)
  await visitConnected(page, `/tasks/${taskId}/edit`)
  await expect(page.locator("#task-drawer-repository-input")).toHaveValue("~/Projects")

  await removeTasks(page, title)
})

test("the task header edits the repository with the picker", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  const title = `E2E header picker ${Date.now()}`

  await visitConnected(page, "/")
  await page.locator("#new-task").click()
  await page.locator("#task-form input[name='form[title]']").fill(title)
  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()
  await page.locator("#board article", { hasText: title }).getByRole("link").click()
  await page.waitForURL(/\/tasks\/[0-9a-f-]+\/edit/)
  const taskId = page.url().match(/tasks\/([0-9a-f-]+)/)[1]

  await visitConnected(page, `/tasks/${taskId}`)
  await page.locator("#task-repository-edit").click()
  await page.locator("#task-repository-picker-browse").click()
  await page.locator("#task-repository-picker-folders [data-choose='~/Projects/notes']").click()
  await expect(page.locator("#task-repository-picker-input")).toHaveValue("~/Projects/notes")
  await page.screenshot({ path: "test-results/screens/task-header-repository.png", animations: "disabled" })
  await page.locator("#task-repository-save").click()
  await expect(page.locator("#task-repository-edit")).toContainText("~/Projects/notes")
  await page.reload()
  await expect(page.locator("#task-repository-edit")).toContainText("~/Projects/notes")

  await removeTasks(page, title)
})
