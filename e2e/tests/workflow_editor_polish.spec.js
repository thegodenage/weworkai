const { test, expect } = require("@playwright/test")
const { visitConnected } = require("./helpers")
const { block, connect, edges, newWorkflow, nodes } = require("./editor_helpers")

// The editor's finer points: what undo selects, arrows sharing a dot, the page's own
// messages next to its toolbar. Own workflows (prefix "WP"); the seeded default is only
// looked at, never saved. Runs no task.
const PREFIX = "WP"
const SHOTS = "test-results/screens"

test.use({ viewport: { width: 1440, height: 900 } })
test.setTimeout(120_000)

const endOf = (d) => d.trim().split(/[\s,]+/).slice(-2).map(Number)
const overlap = (a, b) => a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height

test("undo brings back what was deleted, selected", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await newWorkflow(page, `${PREFIX} undo`)
  await page.locator("#palette-role-coder").click()
  await page.locator("#palette-role-reviewer").click()
  await connect(page, block(page, "Coder"), "bottom", block(page, "Reviewer"), "top")
  await expect(edges(page)).toHaveCount(1)
  await page.locator("#wf-inspector-condition").selectOption("done")

  await block(page, "Reviewer").locator("[data-label]").click()
  await page.keyboard.press("Delete")
  await expect(nodes(page)).toHaveCount(1)
  await page.keyboard.press("ControlOrMeta+z")
  await expect(block(page, "Reviewer")).toHaveClass(/is-selected/)
  await expect(edges(page)).toHaveCount(1)
  await expect(page.locator("#wf-inspector-label")).toHaveValue("Reviewer")

  await page.locator("#wf-viewport .wf-edge-label").click()
  await page.keyboard.press("Delete")
  await expect(edges(page)).toHaveCount(0)
  await page.keyboard.press("ControlOrMeta+z")
  await expect(page.locator("#wf-viewport .wf-edge.is-selected")).toHaveCount(1)
  await expect(page.locator("#wf-inspector-condition")).toBeVisible()
})

test("arrows meeting on one dot fan out, their labels apart", async ({ page }) => {
  await visitConnected(page, "/workflows")
  await page.locator("#workflows li").first().locator("[id$=-open]").click()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  await expect(nodes(page)).toHaveCount(7)

  // Docker reviewer's findings and Approve's continue both come into the Coder's bottom dot.
  const coder = await block(page, "Coder").getAttribute("data-node-id")
  const into = page.locator(`#wf-viewport .wf-edge[data-to="${coder}"] .wf-edge-line`)
  const ends = await into.evaluateAll((paths) => paths.map((path) => path.getAttribute("d")))
  const points = ends.map(endOf)
  expect(points.length).toBeGreaterThanOrEqual(3)
  const keys = new Set(points.map(([x, y]) => `${Math.round(x)},${Math.round(y)}`))
  expect(keys.size).toBe(points.length)

  const labels = await page.locator("#wf-viewport .wf-edge-label").evaluateAll((all) =>
    all.map((label) => {
      const box = label.getBoundingClientRect()
      return { x: box.x, y: box.y, width: box.width, height: box.height }
    }),
  )
  for (const [index, label] of labels.entries()) {
    for (const other of labels.slice(index + 1)) expect(overlap(label, other)).toBe(false)
  }
  await page.screenshot({ path: `${SHOTS}/editor-default.png`, animations: "disabled" })
})

test("the page's own messages keep clear of the toolbar's Save", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await newWorkflow(page, `${PREFIX} offline`)

  // As LiveView shows it when the connection drops.
  await page.locator("#client-error").evaluate((flash) => {
    flash.removeAttribute("hidden")
    flash.style.display = "block"
  })
  const flash = await page.locator("#client-error").boundingBox()
  const save = await page.locator("#wf-save").boundingBox()
  expect(overlap(flash, save)).toBe(false)
  await page.screenshot({ path: `${SHOTS}/editor-flash.png`, animations: "disabled" })
})

test("an empty canvas guides the first block; double-click searches blocks to add there", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await newWorkflow(page, `${PREFIX} first`)
  await expect(page.locator("#wf-first-steps")).toBeVisible()
  await page.screenshot({ path: `${SHOTS}/editor-first-run.png`, animations: "disabled" })

  await page.locator("#wf-empty-planner").click()
  await expect(block(page, "Planner").locator(".wf-start")).toBeVisible()
  await expect(page.locator("#wf-empty")).toBeHidden()

  // Double-click on the empty canvas, search, Enter: the block lands where it was asked for.
  const canvas = await page.locator("#wf-viewport").boundingBox()
  const at = { x: canvas.x + canvas.width - 220, y: canvas.y + canvas.height - 160 }
  await page.mouse.dblclick(at.x, at.y)
  await expect(page.locator("#wf-quick-search")).toBeFocused()
  // Other specs' agents are in the palette too: the role's subtitle is unique.
  await page.keyboard.type("any docker")
  await expect(page.locator("#wf-quick-list [role=option]")).toHaveCount(1)
  await page.screenshot({ path: `${SHOTS}/editor-quick-add.png`, animations: "disabled" })
  await page.keyboard.press("Enter")
  await expect(page.locator("#wf-quick-add")).toBeHidden()
  const added = await block(page, "Docker reviewer").boundingBox()
  expect(Math.abs(added.x + added.width / 2 - at.x)).toBeLessThan(40)
  expect(Math.abs(added.y + added.height / 2 - at.y)).toBeLessThan(40)

  // Escape closes it; the canvas menu opens it too.
  await page.mouse.dblclick(canvas.x + 120, canvas.y + 120)
  await page.keyboard.press("Escape")
  await expect(page.locator("#wf-quick-add")).toBeHidden()
  await page.mouse.click(canvas.x + 120, canvas.y + 120, { button: "right" })
  await page.locator("#wf-menu-add").click()
  await expect(page.locator("#wf-quick-search")).toBeFocused()
  await page.keyboard.press("Escape")
})

test("a block dropped on a dot comes connected; arrows delete inline and re-attach from the inspector", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await newWorkflow(page, `${PREFIX} drop`)
  await page.locator("#palette-role-coder").click()
  const coder = block(page, "Coder")

  // Dragged from the palette onto the Coder's right dot.
  const item = page.locator("#palette-role-reviewer")
  const from = await item.boundingBox()
  await coder.hover({ position: { x: 12, y: 12 } })
  const dot = await coder.locator("[data-port=right]").boundingBox()
  await page.mouse.move(from.x + 20, from.y + 10)
  await page.mouse.down()
  await page.mouse.move(dot.x, dot.y, { steps: 8 })
  await page.mouse.move(dot.x + dot.width / 2, dot.y + dot.height / 2, { steps: 4 })
  await expect(coder).toHaveClass(/is-drop-target/)
  await page.mouse.up()

  await expect(block(page, "Reviewer")).toBeVisible()
  await expect(edges(page)).toHaveCount(1)
  await expect(page.locator("#wf-inspector-condition")).toBeFocused()
  const [left, right] = [await coder.boundingBox(), await block(page, "Reviewer").boundingBox()]
  expect(right.x).toBeGreaterThan(left.x + left.width)
  await page.locator("#wf-inspector-condition").selectOption("done")

  // To another block from the inspector, without the mouse on the canvas.
  await page.locator("#palette-role-qa").click()
  await page.locator("#wf-edge-label-" + (await edges(page).first().getAttribute("data-edge-id"))).click()
  await page.locator("#wf-inspector-to").selectOption({ label: "Docker reviewer" })
  const docker = await block(page, "Docker reviewer").getAttribute("data-node-id")
  await expect(edges(page).first()).toHaveAttribute("data-to", docker)
  await page.keyboard.press("ControlOrMeta+z")
  await expect(edges(page).first()).not.toHaveAttribute("data-to", docker)

  // Keyboard: Tab onto an arrow's label selects it; Enter edits its condition.
  await block(page, "Coder").focus()
  const label = page.locator("#wf-viewport .wf-edge-label").first()
  await label.focus()
  await expect(page.locator("#wf-viewport .wf-edge.is-selected")).toHaveCount(1)
  await expect(label).toBeFocused()
  await page.keyboard.press("Enter")
  await expect(page.locator("#wf-inspector-condition")).toBeFocused()

  // The selected arrow's × deletes it.
  await page.locator("[id^=wf-edge-delete-]").click()
  await expect(edges(page)).toHaveCount(0)
  await page.keyboard.press("ControlOrMeta+z")
  await expect(edges(page)).toHaveCount(1)
  await page.screenshot({ path: `${SHOTS}/editor-arrow-selected.png`, animations: "disabled" })
})

test("blocks move into and out of nested groups by where they are dropped", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await newWorkflow(page, `${PREFIX} nested`)
  for (const id of ["#palette-role-coder", "#palette-role-reviewer", "#palette-role-qa"]) await page.locator(id).click()
  const groups = page.locator("#wf-viewport .wf-group")
  const count = (label) =>
    groups.filter({ has: page.locator(".wf-group-label", { hasText: new RegExp(`^${label}$`) }) }).locator(".wf-group-count")

  // Coder and Reviewer in Group 1; Group 1 and QA in Group 2.
  await block(page, "Coder").locator("[data-label]").click()
  await block(page, "Reviewer").locator("[data-label]").click({ modifiers: ["Shift"] })
  await page.keyboard.press("ControlOrMeta+g")
  await expect(count("Group 1")).toHaveText("2 blocks")
  await block(page, "Docker reviewer").locator("[data-label]").click({ modifiers: ["Shift"] })
  await page.keyboard.press("ControlOrMeta+g")
  await expect(count("Group 2")).toHaveText("3 blocks")
  await page.locator("#wf-fit").click()

  // QA dragged into Group 1's rectangle joins it; back out (still inside Group 2) leaves it.
  const qa = block(page, "Docker reviewer")
  const start = await qa.boundingBox()
  const inner = await groups.filter({ hasText: "Group 1" }).first().boundingBox()
  const grab = { x: start.x + 30, y: start.y + start.height / 2 }
  const drag = async (to) => {
    await page.mouse.move(grab.x, grab.y)
    await page.mouse.down()
    await page.mouse.move(to.x, to.y, { steps: 10 })
    await page.mouse.up()
  }
  await drag({ x: inner.x + inner.width / 2, y: inner.y + inner.height - 20 })
  await expect(count("Group 1")).toHaveText("3 blocks")
  await expect(count("Group 2")).toHaveText("3 blocks")
  // Group 1 grew to hold it, and Group 2 around it.
  const [joined, grown, around] = [await qa.boundingBox(), await groups.filter({ hasText: "Group 1" }).first().boundingBox(), await groups.filter({ hasText: "Group 2" }).first().boundingBox()]
  expect(grown.x + grown.width).toBeGreaterThan(joined.x + joined.width)
  expect(grown.y + grown.height).toBeGreaterThan(joined.y + joined.height)
  expect(around.x + around.width).toBeGreaterThan(grown.x + grown.width)
  await page.screenshot({ path: `${SHOTS}/editor-nested.png`, animations: "disabled" })
  const moved = await qa.boundingBox()
  grab.x = moved.x + 30
  grab.y = moved.y + moved.height / 2
  await drag({ x: start.x + 30, y: start.y + start.height / 2 })
  await expect(count("Group 1")).toHaveText("2 blocks")
  await expect(count("Group 2")).toHaveText("3 blocks")

  // Out of both: the outer group keeps the other two.
  const outer = await groups.filter({ hasText: "Group 2" }).first().boundingBox()
  const again = await qa.boundingBox()
  grab.x = again.x + 30
  grab.y = again.y + again.height / 2
  await drag({ x: outer.x + outer.width + 200, y: outer.y + outer.height + 120 })
  await expect(count("Group 2")).toHaveText("2 blocks")
})
