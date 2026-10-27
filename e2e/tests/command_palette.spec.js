const { test, expect } = require("@playwright/test")
const { removeTasks, setColorScheme, visitConnected } = require("./helpers")

const TITLE_PREFIX = "CP palette task "

test.use({ viewport: { width: 1440, height: 900 } })

async function createTask(page, title) {
  await visitConnected(page, "/")
  await page.locator("#new-task").click()
  await page.locator("#task-form input[name='form[title]']").fill(title)
  await page.locator("#task-form input[name='form[repository]']").fill("/repos/app")
  await page.locator("#task-form").getByRole("button", { name: "Create" }).click()
  await expect(page.locator("#task-form")).toHaveCount(0)
}

const dialog = (page) => page.locator("#command-palette-dialog")
const input = (page) => page.locator("#command-palette-input")
const active = (page) => page.locator("#command-palette-results [role=option][aria-selected=true]")

test("the palette jumps to a task by keyboard and remembers it", async ({ page }) => {
  page.on("dialog", (confirm) => confirm.accept())
  const title = `${TITLE_PREFIX}${Date.now()}`
  await createTask(page, title)

  await visitConnected(page, "/dashboard")
  const trigger = page.locator("#command-palette-trigger")
  await trigger.focus()
  await page.keyboard.press("ControlOrMeta+k")
  await expect(dialog(page)).toBeVisible()
  await expect(input(page)).toBeFocused()
  await expect(page.locator("#command-palette-group-actions")).toBeVisible()
  await expect(active(page)).toHaveCount(1)

  // Fuzzy: "cppltsk" is in the title in order, not as one run.
  await input(page).fill("cppltsk")
  const option = page.locator("#command-palette-group-tasks [role=option]", { hasText: title })
  await expect(option).toBeVisible()
  await expect(option.locator(".text-primary").first()).toHaveText("CP")

  for (const scheme of ["light", "dark"]) {
    await setColorScheme(page, scheme)
    await page.screenshot({ path: `test-results/screens/command-palette-${scheme}.png`, animations: "disabled" })
  }

  await page.keyboard.press("Escape")
  await expect(dialog(page)).toBeHidden()
  await expect(trigger).toBeFocused()

  // Its timestamp makes it the best match whatever other specs' tasks are called.
  await page.keyboard.press("ControlOrMeta+k")
  await input(page).fill(`cp task ${title.slice(TITLE_PREFIX.length)}`)
  await expect(active(page)).toHaveAttribute("data-href", /^\/tasks\//)
  await expect(active(page)).toContainText(title)
  const id = await active(page).getAttribute("id")
  await expect(input(page)).toHaveAttribute("aria-activedescendant", id)
  await page.keyboard.press("Enter")
  await expect(page).toHaveURL(/\/tasks\/[0-9a-f-]{36}$/)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()

  // "/" opens it outside a field; the pick is listed first under Recent.
  await page.locator("body").click({ position: { x: 5, y: 5 } })
  await page.keyboard.press("/")
  await expect(dialog(page)).toBeVisible()
  const recent = page.locator("#command-palette-group-recent [role=option]").first()
  await expect(recent).toContainText(title)
  await expect(recent).toHaveAttribute("aria-selected", "true")
  await page.screenshot({ path: "test-results/screens/command-palette-recent.png", animations: "disabled" })

  await page.keyboard.press("Escape")
  await removeTasks(page, title)
})

test("arrows move through the groups and actions run", async ({ page }) => {
  await visitConnected(page, "/dashboard")
  await setColorScheme(page, "light")
  await page.locator("#command-palette-trigger").click()
  await expect(dialog(page)).toBeVisible()

  await input(page).fill("toggle theme")
  await expect(active(page)).toContainText("Toggle theme")
  await page.keyboard.press("Enter")
  await expect(dialog(page)).toBeHidden()
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark")

  await page.keyboard.press("ControlOrMeta+k")
  const options = page.locator("#command-palette-results [role=option]")
  await expect(options.first()).toHaveAttribute("aria-selected", "true")
  await page.keyboard.press("ArrowUp")
  await expect(options.last()).toHaveAttribute("aria-selected", "true")
  await page.keyboard.press("ArrowDown")
  await expect(options.first()).toHaveAttribute("aria-selected", "true")

  // Other specs' tasks may match too, so pick the page by pointer.
  await input(page).fill("audt")
  const audit = page.locator("#command-palette-group-pages [role=option]", { hasText: "Audit" })
  await audit.hover()
  await expect(audit).toHaveAttribute("aria-selected", "true")
  await audit.click()
  await expect(page).toHaveURL(/\/audit$/)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()

  // A click on the backdrop closes it; "/" typed in its field is just text.
  await page.keyboard.press("ControlOrMeta+k")
  await expect(dialog(page)).toBeVisible()
  await page.keyboard.type("a/b")
  await expect(input(page)).toHaveValue("a/b")
  await dialog(page).click({ position: { x: 5, y: 5 } })
  await expect(dialog(page)).toBeHidden()
})
