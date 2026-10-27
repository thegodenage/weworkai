const { test, expect } = require("@playwright/test")
const { removeTasks, setColorScheme, visitConnected } = require("./helpers")

// Sub-tasks and blockers on the task page and the board. Closing the blocker notifies the
// blocked task, so this runs after the specs that count the bell (playwright.config.js).
const PREFIX = "DP"

test.use({ viewport: { width: 1440, height: 900 } })
test.setTimeout(90_000)

async function createTask(page, title) {
  await visitConnected(page, "/tasks/new")
  await page.locator("#task-form input[name='form[title]']").fill(title)
  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()
  await expect(page.locator("#task-form")).toHaveCount(0)
  return page.locator("#board article", { hasText: title }).getAttribute("data-task-id")
}

async function screenshotBoth(page, locator, name) {
  for (const scheme of ["light", "dark"]) {
    await setColorScheme(page, scheme)
    await locator.screenshot({ path: `test-results/screens/${name}-${scheme}.png`, animations: "disabled" })
  }
}

test("a blocked task waits on its blocker and tracks its sub-tasks", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  const stamp = Date.now()
  const epic = `${PREFIX} Epic ${stamp}`
  const api = `${PREFIX} API ${stamp}`
  const epicId = await createTask(page, epic)
  const apiId = await createTask(page, api)

  await visitConnected(page, `/tasks/${epicId}`)
  const section = page.locator("#task-dependencies")
  await expect(page.locator("#task-blocked")).toHaveCount(0)

  for (const title of ["Schema", "Endpoints"]) {
    await page.locator("#task-dependencies-subtask-title").fill(`${PREFIX} ${title} ${stamp}`)
    await page.locator("#task-dependencies-add-subtask").click()
    await expect(section.locator("#task-dependencies-children li", { hasText: title })).toBeVisible()
  }
  await expect(page.locator("#task-dependencies-progress")).toContainText("0/2")
  await expect(page.locator("#task-dependencies-subtask-title")).toHaveValue("")
  const childRow = await section.locator("#task-dependencies-children li").first().getAttribute("id")
  const childId = childRow.replace("task-dependencies-child-", "")

  await page.locator("#task-dependencies-blocker-select").selectOption(apiId)
  await page.locator("#task-dependencies-add-blocker").click()
  await expect(page.locator(`#task-dependencies-blocker-${apiId}`)).toContainText(api)
  await expect(page.locator("#task-blocked")).toBeVisible()
  await expect(page.locator("#task-blocked")).toHaveAttribute("title", `Blocked by ${api}`)

  await screenshotBoth(page, page.locator("#task-header"), "dependencies-header")
  await screenshotBoth(page, section, "dependencies-section")

  // The reverse link would close a loop: refused, saying why.
  await visitConnected(page, `/tasks/${apiId}`)
  await expect(page.locator("#task-dependencies-dependents")).toContainText(epic)
  await page.locator("#task-dependencies-blocker-select").selectOption(epicId)
  await page.locator("#task-dependencies-add-blocker").click()
  await expect(page.locator("#task-dependencies-error")).toContainText("wait on each other")
  await expect(page.locator(`#task-dependencies-blocker-${epicId}`)).toHaveCount(0)

  // A sub-task names its parent.
  await visitConnected(page, `/tasks/${childId}`)
  await expect(page.locator("#task-dependencies-parent")).toContainText(epic)

  await visitConnected(page, "/")
  const card = page.locator(`#board article[data-task-id="${epicId}"]`)
  await expect(card.locator(`#task-${epicId}-blocked`)).toBeVisible()
  await expect(card.locator(`#task-${epicId}-subtasks`)).toContainText("0/2")
  await screenshotBoth(page, card, "dependencies-card")
  await setColorScheme(page, "light")
  await page.screenshot({ path: "test-results/screens/dependencies-board.png", animations: "disabled" })

  // Closing the blocker frees the card live.
  await visitConnected(page, `/tasks/${apiId}/edit`)
  await page.locator("#task-drawer-status select").selectOption("done")
  await expect(card.locator(`#task-${epicId}-blocked`)).toHaveCount(0)

  await removeTasks(page, PREFIX)
})
