const { test, expect } = require("@playwright/test")
const { removeTasks, visitConnected } = require("./helpers")

// Screenshots pasted into a task's description with ⌘V attach to the task, referenced at the cursor.
const PREFIX = "PS"
// A 1×1 PNG.
const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
const REFERENCE = /!\[screenshot-[\d-]+\.png\]\(screenshot-[\d-]+\.png\)/g

// What ⌘V of a screenshot hands the page: one file named image.png and no text.
async function pasteScreenshot(textarea) {
  await textarea.focus()
  await textarea.evaluate((el, png) => {
    const bytes = Uint8Array.from(atob(png), (c) => c.charCodeAt(0))
    const clipboardData = new DataTransfer()
    clipboardData.items.add(new File([bytes], "image.png", { type: "image/png" }))
    el.dispatchEvent(new ClipboardEvent("paste", { clipboardData, bubbles: true, cancelable: true }))
  }, PNG)
}

test.afterEach(async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await removeTasks(page, PREFIX)
})

test("a screenshot pasted into a new task's description is attached on create", async ({ page }) => {
  const title = `${PREFIX} New ${Date.now()}`
  await visitConnected(page, "/tasks/new")
  await page.locator("#task-form input[name='form[title]']").fill(title)

  const description = page.locator("#task-form-description-input")
  await pasteScreenshot(description)
  await expect(page.locator("#task-form [id^='upload-']")).toHaveCount(1)
  await expect(page.locator("#task-form [id^='upload-']")).toContainText(/screenshot-.*\.png/)
  await expect(description).toHaveValue(REFERENCE)

  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()
  await expect(page.locator("#task-form")).toHaveCount(0)

  const taskId = await page.locator("#board article", { hasText: title }).getAttribute("data-task-id")
  await visitConnected(page, `/tasks/${taskId}/edit`)
  await expect(page.locator("#task-drawer-attachment-list li")).toHaveCount(1)
  await expect(page.locator("#task-drawer-description-input")).toHaveValue(REFERENCE)
})

test("each screenshot pasted in the drawer attaches as its own file and previews", async ({ page }) => {
  const title = `${PREFIX} Drawer ${Date.now()}`
  await visitConnected(page, "/tasks/new")
  await page.locator("#task-form input[name='form[title]']").fill(title)
  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()
  const taskId = await page.locator("#board article", { hasText: title }).getAttribute("data-task-id")

  await visitConnected(page, `/tasks/${taskId}/edit`)
  const description = page.locator("#task-drawer-description-input")
  await pasteScreenshot(description)
  await expect(page.locator("#task-drawer-attachment-list li")).toHaveCount(1)
  await pasteScreenshot(description)
  await expect(page.locator("#task-drawer-attachment-list li")).toHaveCount(2)
  expect((await description.inputValue()).match(REFERENCE)).toHaveLength(2)

  await page.locator("#task-drawer-description-preview-tab").click()
  await expect(page.locator("#task-drawer-description-preview img[src^='/attachments/']")).toHaveCount(2)
})
