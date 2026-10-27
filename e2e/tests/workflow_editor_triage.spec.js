const { test, expect } = require("@playwright/test")
const { visitConnected } = require("./helpers")
const { block, connect, edges, newWorkflow } = require("./editor_helpers")

// A triage block from the palette: its arrows pick a severity (or clean), the graph saves
// without problems and comes back after a reload. Own workflow (prefix "WT"); runs no task.
const PREFIX = "WT"
const WORKFLOW = `${PREFIX} triage`
const SHOTS = "test-results/screens"

test.use({ viewport: { width: 1440, height: 900 } })
test.setTimeout(120_000)

test.afterAll(async ({ browser }) => {
  const page = await browser.newPage()
  page.on("dialog", (dialog) => dialog.accept())
  await visitConnected(page, "/workflows")
  const buttons = page.locator(`[aria-label^="Delete ${WORKFLOW}"]`)
  for (let count = await buttons.count(); count > 0; count--) {
    await buttons.first().click()
    await expect(buttons).toHaveCount(count - 1)
  }
  await page.close()
})

test("a triage block routes the reviewer's findings by severity", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await newWorkflow(page, WORKFLOW)

  await page.locator("#palette-role-reviewer").click()
  await page.locator("#palette-triage").click()
  await expect(page.locator("#wf-inspector-triage")).toBeVisible()
  await expect(page.locator("#wf-inspector-label")).toHaveValue("Triage")
  await page.locator("#palette-column-done").click()

  await connect(page, block(page, "Reviewer"), "bottom", block(page, "Triage"), "top")
  await expect(edges(page)).toHaveCount(1)

  await connect(page, block(page, "Triage"), "bottom", block(page, "Done"), "top")
  await expect(edges(page)).toHaveCount(2)
  const condition = page.locator("#wf-inspector-condition")
  await expect(condition.locator("option")).toHaveText(["Always (any other outcome)", "high", "medium", "low", "clean"])
  await condition.selectOption("clean")
  await expect(page.locator("#wf-viewport .wf-edge-label", { hasText: "clean" })).toBeVisible()

  await expect(page.locator("#wf-problem-count")).toBeHidden()
  await page.locator("#wf-save").click()
  await expect(page.locator("#wf-save")).toContainText("Saved")

  await page.reload()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await expect(block(page, "Triage")).toBeVisible()
  await expect(page.locator("#wf-viewport .wf-edge-label", { hasText: "clean" })).toBeVisible()
  await block(page, "Triage").locator("[data-label]").click()
  await expect(page.locator("#wf-inspector-triage")).toBeVisible()
  await page.screenshot({ path: `${SHOTS}/editor-triage.png`, animations: "disabled" })
})
