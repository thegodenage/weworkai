const { test, expect } = require("@playwright/test")
const { block, center, connect, drag, edges, newWorkflow } = require("./editor_helpers")

// Where things land in the editor: arrows' dots after blocks move, label sizes, snap
// guides, a block dropped on a dot. Own workflows (prefix "WL"); runs no task.
const PREFIX = "WL"
const SHOTS = "test-results/screens"

test.use({ viewport: { width: 1440, height: 900 } })
test.setTimeout(120_000)

const overlap = (a, b) => a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height

// Drags a block by its label to put its centre at `to`.
async function moveBlock(page, node, to) {
  const grab = await center(node.locator("[data-label]"))
  const box = await node.boundingBox()
  const offset = { x: grab.x - (box.x + box.width / 2), y: grab.y - (box.y + box.height / 2) }
  await drag(page, grab, { x: to.x + offset.x, y: to.y + offset.y })
}

async function dropOnDot(page, item, node, side) {
  const from = await page.locator(item).boundingBox()
  await node.hover({ position: { x: 12, y: 12 } })
  const dot = await node.locator(`[data-port=${side}]`).boundingBox()
  await page.mouse.move(from.x + 20, from.y + 10)
  await page.mouse.down()
  await page.mouse.move(dot.x, dot.y, { steps: 8 })
  await page.mouse.move(dot.x + dot.width / 2, dot.y + dot.height / 2, { steps: 4 })
  await page.mouse.up()
}

test("an arrow's dots follow its blocks, unless an end was attached by hand", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await newWorkflow(page, `${PREFIX} ports`)
  await page.locator("#palette-role-coder").click()
  await page.locator("#palette-role-reviewer").click()
  const [coder, reviewer] = [block(page, "Coder"), block(page, "Reviewer")]
  await connect(page, coder, "bottom", reviewer, "top")
  await page.locator("#wf-inspector-condition").selectOption("done")
  const arrow = edges(page).first()
  await expect(arrow).toHaveAttribute("data-from-port", "bottom")

  // Beside the coder: the arrow leaves its right side for the reviewer's left.
  const left = await coder.boundingBox()
  await moveBlock(page, reviewer, { x: left.x + left.width + 200, y: left.y + left.height / 2 })
  await expect(arrow).toHaveAttribute("data-from-port", "right")
  await expect(arrow).toHaveAttribute("data-to-port", "left")

  // Its end dragged onto the reviewer's bottom dot stays there when blocks move.
  await page.locator(`#wf-edge-label-${await arrow.getAttribute("data-edge-id")}`).click()
  const handle = page.locator("[data-edge-handle=to]")
  await reviewer.hover({ position: { x: 12, y: 12 } })
  const bottom = await center(reviewer.locator("[data-port=bottom]"))
  await drag(page, await center(handle), bottom)
  await expect(arrow).toHaveAttribute("data-to-port", "bottom")
  await expect(arrow).toHaveAttribute("data-pinned", "true")
  const placed = await reviewer.boundingBox()
  await moveBlock(page, reviewer, { x: placed.x + placed.width / 2, y: placed.y + 260 })
  await expect(arrow).toHaveAttribute("data-from-port", "right")
  await expect(arrow).toHaveAttribute("data-to-port", "bottom")

  // The inspector hands the dots back to the editor.
  await page.locator(`#wf-edge-label-${await arrow.getAttribute("data-edge-id")}`).click()
  await page.locator("#wf-inspector-unpin").click()
  await expect(arrow).not.toHaveAttribute("data-pinned", "true")
  await expect(arrow).toHaveAttribute("data-to-port", "top")
  await page.keyboard.press("ControlOrMeta+s")
  await expect(page.locator("#wf-save [data-label]")).toHaveText(/Saved/)
  await page.reload()
  await expect(edges(page).first()).toHaveAttribute("data-to-port", "top")
})

test("a selected arrow's × sits on its label's corner, however wide the label", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await newWorkflow(page, `${PREFIX} labels`)
  await page.locator("#palette-human-any").click()
  await page.locator("#palette-role-coder").click()
  await connect(page, block(page, "Review"), "bottom", block(page, "Coder"), "top")
  await page.locator("#wf-inspector-condition").fill("MMMMMMMMMMMMMMMMMMMMMMMM")
  await page.locator("#wf-inspector-condition").press("Enter")

  const label = page.locator("#wf-viewport .wf-edge-label.is-selected")
  await expect(label).toContainText("MMMMMMMMMMMMMMMMMMMMMMMM")
  const pill = await label.boundingBox()
  const cross = await page.locator("[id^=wf-edge-delete-]").boundingBox()
  expect(Math.abs(cross.x + cross.width / 2 - (pill.x + pill.width))).toBeLessThan(4)
  expect(cross.y + cross.height / 2).toBeLessThan(pill.y + 2)
  await page.screenshot({ path: `${SHOTS}/editor-wide-label.png`, animations: "disabled" })
})

test("dragging a block shows guides where it lines up with another", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await newWorkflow(page, `${PREFIX} guides`)
  await page.locator("#palette-role-coder").click()
  await page.locator("#palette-role-reviewer").click()
  const reviewer = block(page, "Reviewer")
  const grab = await center(reviewer.locator("[data-label]"))

  await page.mouse.move(grab.x, grab.y)
  await page.mouse.down()
  await page.mouse.move(grab.x + 300, grab.y + 7, { steps: 8 })
  await page.mouse.move(grab.x, grab.y + 90, { steps: 8 })
  // Still in the coder's column: its left edge, centre and right edge line up.
  await expect(page.locator("#wf-viewport .wf-guide")).not.toHaveCount(0)
  await page.screenshot({ path: `${SHOTS}/editor-guides.png`, animations: "disabled" })
  await page.mouse.up()
  await expect(page.locator("#wf-viewport .wf-guide")).toHaveCount(0)
})

test("a block dropped on a dot lands clear of the blocks already there", async ({ page }) => {
  page.on("dialog", (dialog) => dialog.accept())
  await newWorkflow(page, `${PREFIX} drop`)
  await page.locator("#palette-role-coder").click()
  const coder = block(page, "Coder")
  await dropOnDot(page, "#palette-role-reviewer", coder, "right")
  await expect(block(page, "Reviewer")).toBeVisible()
  await page.locator("#wf-viewport").click({ position: { x: 20, y: 20 } })

  await dropOnDot(page, "#palette-role-qa", coder, "right")
  const docker = block(page, "Docker reviewer")
  await expect(docker).toBeVisible()
  await expect(edges(page)).toHaveCount(2)
  const [taken, landed] = [await block(page, "Reviewer").boundingBox(), await docker.boundingBox()]
  expect(overlap(taken, landed)).toBe(false)
  expect(landed.x).toBeGreaterThan((await coder.boundingBox()).x)
})
