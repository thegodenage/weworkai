const { test, expect } = require("@playwright/test")
const { removeTasks, visitConnected } = require("./helpers")
const { block, connect, newWorkflow, nodes } = require("./editor_helpers")

// The editor keeps work safe: drafts survive reloads, workflows with problems save as
// drafts, a save over another tab's asks first, leaving asks once (also back / forward).
// Then the canvas's trackpad gestures, the palette's sections and the toasts over it.
// Own workflows and tasks (prefix "WS"); its decision notifications would disturb
// task_review.spec.js's count, so it runs after (playwright.config.js).
const PREFIX = "WS"
const SHOTS = "test-results/screens"

test.use({ viewport: { width: 1440, height: 900 } })
test.setTimeout(180_000)

const zoom = async (page) => parseInt(await page.locator("#wf-zoom-reset").textContent(), 10)
const world = (page) => page.locator("#wf-viewport [data-world]").getAttribute("style")

test("unsaved changes come back after a reload; problems save as a draft", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  const editor = await newWorkflow(page, `${PREFIX} draft`)

  // A human block alone: it needs a named arrow out, so the workflow has problems.
  await page.locator("#palette-human-any").click()
  await expect(nodes(page)).toHaveCount(1)
  await expect(page.locator("#wf-dirty")).toBeVisible()
  await expect(page.locator("#wf-problem-count")).toBeVisible()

  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await expect(nodes(page)).toHaveCount(0)
  await expect(page.locator("#wf-banner")).toContainText("You have unsaved changes")
  await page.screenshot({ path: `${SHOTS}/editor-restore.png`, animations: "disabled" })
  await page.locator("#wf-draft-restore").click()
  await expect(nodes(page)).toHaveCount(1)
  await expect(page.locator("#wf-banner")).toBeHidden()
  await expect(page.locator("#wf-dirty")).toBeVisible()

  // Saved with its problems, which keep tasks from running it.
  await page.locator("#wf-save").click()
  await expect(page.locator("#wf-save")).toContainText("Saved as draft")
  await expect(page.locator("#wf-dirty")).toBeHidden()
  await expect(page.locator("#wf-problem-count")).toBeVisible()
  await expect(page.locator("#wf-draft-note")).toBeVisible()

  // Nothing left to restore; the list marks it.
  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await expect(nodes(page)).toHaveCount(1)
  await expect(page.locator("#wf-banner")).toBeHidden()
  await visitConnected(page, "/workflows")
  await expect(page.locator("#workflows li", { hasText: `${PREFIX} draft` }).locator("[id$=-problems]")).toHaveText(/1 problem/)
  expect(editor).toContain("/workflows/")
})

test("a save over another tab's save asks to overwrite it", async ({ page, context }) => {
  page.on("dialog", (dialog) => dialog.accept())
  const editor = await newWorkflow(page, `${PREFIX} two tabs`)
  const other = await context.newPage()
  other.on("dialog", (dialog) => dialog.accept())
  await visitConnected(other, editor)

  await page.locator("#palette-role-coder").click()
  await page.keyboard.press("ControlOrMeta+s")
  await expect(page.locator("#wf-save")).toContainText("Saved")

  await other.locator("#palette-role-planner").click()
  await other.locator("#wf-save").click()
  await expect(other.locator("#wf-banner")).toContainText("saved elsewhere")
  await expect(other.locator("#wf-dirty")).toBeVisible()
  await other.locator("#wf-stale-overwrite").click()
  await expect(other.locator("#wf-save")).toContainText("Saved")
  await expect(other.locator("#wf-dirty")).toBeHidden()

  await page.reload()
  await expect(block(page, "Planner")).toBeVisible()
  await expect(block(page, "Coder")).toHaveCount(0)
})

test("leaving with unsaved changes asks once, back and forward included", async ({ page }) => {
  const dialogs = []
  page.on("dialog", (dialog) => {
    dialogs.push(dialog.type())
    dialog.message().startsWith("Leave without saving") && dialogs.length === 1 ? dialog.dismiss() : dialog.accept()
  })
  const editor = await newWorkflow(page, `${PREFIX} leave`)
  await page.locator("#palette-role-coder").click()

  // Back: "stay" keeps the editor and its block.
  await page.evaluate(() => window.history.back())
  await expect.poll(() => dialogs.length).toBe(1)
  await expect(page).toHaveURL(editor)
  await expect(nodes(page)).toHaveCount(1)

  // A link while LiveView is down loads the page anew: one question, not a second on unload.
  dialogs.length = 0
  page.removeAllListeners("dialog")
  page.on("dialog", (dialog) => {
    dialogs.push(dialog.type())
    dialog.accept()
  })
  await page.evaluate(() => window.liveSocket.disconnect())
  await page.locator("#back-to-workflows").click()
  await expect(page).toHaveURL(/\/workflows$/)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  expect(dialogs).toHaveLength(1)
})

test("scrolling pans the canvas; pinch and ⌘ scroll zoom", async ({ page }) => {
  await visitConnected(page, "/workflows")
  await page.locator("#workflows li a[id$=-open]").first().click()
  await expect(nodes(page)).toHaveCount(7)

  // The default reads at 1440px: two rows, fitted at 60% or more.
  expect(await zoom(page)).toBeGreaterThanOrEqual(60)
  await page.screenshot({ path: `${SHOTS}/editor-default.png`, animations: "disabled" })

  const canvas = await page.locator("#wf-viewport").boundingBox()
  await page.mouse.move(canvas.x + 200, canvas.y + 200)
  const before = { zoom: await zoom(page), world: await world(page) }
  await page.mouse.wheel(40, 120)
  await expect.poll(() => world(page)).not.toBe(before.world)
  expect(await zoom(page)).toBe(before.zoom)

  await page.keyboard.down("Control")
  await page.mouse.wheel(0, -40)
  await page.keyboard.up("Control")
  await expect.poll(() => zoom(page)).toBeGreaterThan(before.zoom)
})

test("palette sections fold, count and remember", async ({ page }) => {
  await visitConnected(page, "/workflows")
  await page.locator("#workflows li a[id$=-open]").first().click()
  const columns = page.locator("#wf-palette-columns")
  await expect(columns.locator("[data-count]")).toHaveText("6")

  await columns.locator("summary").click()
  await expect(page.locator("#palette-column-done")).toBeHidden()
  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await expect(page.locator("#palette-column-done")).toBeHidden()

  // A search opens what matches and counts it; clearing it folds the section again.
  await page.locator("#wf-palette-search").fill("done")
  await expect(page.locator("#palette-column-done")).toBeVisible()
  await expect(columns.locator("[data-count]")).toHaveText("1/6")
  await page.locator("#wf-palette-search").fill("")
  await expect(page.locator("#palette-column-done")).toBeHidden()
  await columns.locator("summary").click()
  await expect(page.locator("#palette-column-done")).toBeVisible()
})

test("a burst of notifications shows three toasts, clamped, clear of the inspector", async ({ page, context }) => {
  page.on("dialog", (dialog) => dialog.accept())
  const name = `${PREFIX} decide`
  await newWorkflow(page, name)

  // Review --accepted--> Done: every task waits for a decision at once.
  await page.locator("#palette-human-any").click()
  await page.locator("#palette-column-done").click()
  await connect(page, block(page, "Review"), "bottom", block(page, "Done"), "top")
  await page.locator("#wf-inspector-condition").fill("accepted")
  await page.keyboard.press("Enter")
  await page.locator("#wf-save").click()
  await expect(page.locator("#wf-save")).toContainText(/^\s*Saved\s*$/)

  // Five tasks, each in its drawer in a tab of its own, all moved to todo at once.
  // The last, newest, toast on top: one unbroken word, as long as a title may be.
  const titles = [...[1, 2, 3, 4].map((n) => `${PREFIX} task ${n}`), `${PREFIX} ${"w".repeat(190)}`]
  const drawers = []
  for (const title of titles) {
    const tab = await context.newPage()
    tab.on("dialog", (dialog) => dialog.accept())
    await visitConnected(tab, "/tasks/new")
    await tab.locator("#task-form input[name='form[title]']").fill(title)
    await tab.locator("#task-form input[name='form[repository]']").fill("/repos/app")
    await tab.locator("#task-form select[name='form[workflow_id]']").selectOption({ label: name })
    await tab.locator("#task-form").getByRole("button", { name: "Create" }).click()
    await expect(tab.locator("#task-form")).toHaveCount(0)
    const taskId = await tab.locator("#board article", { hasText: title }).getAttribute("data-task-id")
    await visitConnected(tab, `/tasks/${taskId}/edit`)
    drawers.push(tab)
  }
  for (const tab of drawers) await tab.locator("#task-drawer-status select").selectOption("todo")

  // Other specs running meanwhile may add toasts of their own: three show whatever the count.
  const shown = page.locator("#notification-toasts .notification-toast:not(.hidden)")
  await expect(shown).toHaveCount(3)
  await expect(page.locator("#notification-toasts-more")).toContainText(/\+\d+ more/)
  const long = page.locator("#notification-toasts .notification-toast", { hasText: `${PREFIX} www` }).locator("button span").first()
  expect(await long.evaluate((title) => getComputedStyle(title).webkitLineClamp)).toBe("2")
  await page.screenshot({ path: `${SHOTS}/editor-toasts.png`, animations: "disabled" })

  // The column the toasts stack in: a toast sliding in (another spec's) is briefly offset.
  const inspector = await page.locator("#wf-inspector").boundingBox()
  const column = await page.locator("#notification-toasts").boundingBox()
  expect(column.x + column.width).toBeLessThanOrEqual(inspector.x)
  // Measured in one go: another spec's toast may leave between two separate reads.
  const heights = await shown.evaluateAll((all) => all.map((toast) => toast.getBoundingClientRect().height))
  for (const height of heights) expect(height).toBeLessThan(100)

  // Hovering holds them all; the waiting ones' time only runs once they show.
  await shown.first().hover()
  await page.waitForTimeout(7000)
  await expect(shown).toHaveCount(3)

  // The chip opens the bell's list.
  await page.locator("#notification-toasts-more").click()
  await expect(page.locator("#notification-panel")).toBeVisible()
  await page.screenshot({ path: `${SHOTS}/editor-toasts-more.png`, animations: "disabled" })
  await page.keyboard.press("Escape")
  await expect(page.locator("#notification-panel")).toBeHidden()

  await page.mouse.move(700, 450)
  await page.waitForTimeout(6500)
  await expect(page.locator("#notification-toasts .notification-toast:not(.leaving)")).not.toHaveCount(0)

  // "Dismiss all" clears them.
  // Other specs' notifications may arrive meanwhile: the toasts shown before must all go,
  // without the page raising on the way (removing the focused chip used to).
  const errors = []
  page.on("pageerror", (error) => errors.push(error.message))
  const before = await page.locator("#notification-toasts .notification-toast").evaluateAll((all) => all.map((toast) => toast.dataset.notificationId))
  await page.locator("#notification-toasts-dismiss").click()
  for (const id of before) {
    await expect(page.locator(`#notification-toasts [data-notification-id="${id}"]`)).toHaveCount(0, { timeout: 1000 })
  }
  expect(errors).toEqual([])
  await removeTasks(drawers[0], `${PREFIX} `)
})

test("⌘S while typing in the inspector saves what was typed", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await newWorkflow(page, `${PREFIX} typing`)
  await page.locator("#palette-role-coder").click()
  await block(page, "Coder").locator("[data-label]").click()
  await page.locator("#wf-inspector-label").fill("Builder")
  await page.keyboard.press("ControlOrMeta+s")
  await expect(page.locator("#wf-save")).toContainText("Saved")
  await expect(block(page, "Builder")).toBeVisible()
  await expect(page.locator("#wf-dirty")).toBeHidden()

  // Renaming in place too.
  await block(page, "Builder").locator("[data-label]").dblclick()
  await page.locator("#wf-rename").fill("Maker")
  await page.keyboard.press("ControlOrMeta+s")
  await expect(block(page, "Maker")).toBeVisible()
  await expect(page.locator("#wf-dirty")).toBeHidden()

  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await expect(block(page, "Maker")).toBeVisible()
})

test("typing in the inspector survives the redraw a check of the last edit brings", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await newWorkflow(page, `${PREFIX} instructions`)
  await page.locator("#palette-role-reviewer").click()
  await block(page, "Reviewer").locator("[data-label]").click()

  // The rename commits as the instructions field takes the focus; the server's check of it
  // comes back while typing goes on.
  await page.locator("#wf-inspector-label").fill("Security review")
  await page.locator("#wf-inspector-prompt").click()
  await page.locator("#wf-inspector-prompt").pressSequentially("Only security issues.", { delay: 40 })
  await page.waitForTimeout(800)
  await expect(page.locator("#wf-inspector-prompt")).toHaveValue("Only security issues.")
  await expect(page.locator("#wf-inspector-prompt")).toBeFocused()

  // Shortcuts stay out of the way while typing; ⌘S keeps what was typed.
  await page.keyboard.press("Backspace")
  await page.keyboard.press("Enter")
  await expect(block(page, "Security review")).toBeVisible()
  await page.keyboard.press("ControlOrMeta+s")
  await expect(page.locator("#wf-save")).toContainText("Saved")
  await expect(block(page, "Security review").locator("[data-prompt-mark]")).toBeVisible()
  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await block(page, "Security review").locator("[data-label]").click()
  await expect(page.locator("#wf-inspector-prompt")).toHaveValue("Only security issues")
})

test("blocks added from the palette never land on top of each other", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await newWorkflow(page, `${PREFIX} many`)
  for (let count = 0; count < 25; count++) await page.locator("#palette-role-custom").click()
  await expect(nodes(page)).toHaveCount(25)
  const places = await nodes(page).evaluateAll((all) => all.map((node) => node.style.transform))
  expect(new Set(places).size).toBe(25)
})
