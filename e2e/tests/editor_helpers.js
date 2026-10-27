// Mouse gestures in the workflow editor (/workflows/:id), shared by its specs.
const { expect } = require("@playwright/test")
const { visitConnected } = require("./helpers")

// boundingBox() does not wait: under load a block just added may not be drawn yet.
const center = async (locator) => {
  await locator.waitFor()
  const box = await locator.boundingBox()
  return { x: box.x + box.width / 2, y: box.y + box.height / 2 }
}

async function drag(page, from, to) {
  await page.mouse.move(from.x, from.y)
  await page.mouse.down()
  await page.mouse.move((from.x + to.x) / 2, (from.y + to.y) / 2, { steps: 6 })
  await page.mouse.move(to.x, to.y, { steps: 6 })
  await page.mouse.up()
}

// Drops a palette item on the canvas, `at` relative to the canvas's top left.
async function addBlock(page, item, at) {
  await item.scrollIntoViewIfNeeded()
  const canvas = await page.locator("#wf-viewport").boundingBox()
  await drag(page, await center(item), { x: canvas.x + at.x, y: canvas.y + at.y })
}

const block = (page, label) =>
  page.locator("#wf-viewport .wf-node").filter({ has: page.locator(".wf-node-label", { hasText: new RegExp(`^${label}$`) }) })
const port = (node, side) => node.locator(`[data-port=${side}]`)

async function connect(page, from, fromSide, to, toSide) {
  // A corner, not the centre: a group's centre is one of its blocks.
  await from.hover({ position: { x: 12, y: 12 } })
  const start = await center(port(from, fromSide))
  await to.hover({ position: { x: 12, y: 12 } })
  const end = toSide ? await center(port(to, toSide)) : await center(to)
  await drag(page, start, end)
}

// A new workflow with an empty canvas, opened in the editor.
async function newWorkflow(page, name) {
  await visitConnected(page, "/workflows/new")
  await page.locator("#workflow-form input[name='form[name]']").fill(name)
  await page.locator("#workflow-form select[name='form[source_id]']").selectOption({ label: "An empty canvas" })
  await page.locator("#workflow-form").getByRole("button", { name: "Save" }).click()
  await expect(page.locator("#workflow-name")).toHaveText(name)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible()
  return page.url()
}

const edges = (page) => page.locator("#wf-viewport [data-edges] .wf-edge")
const nodes = (page) => page.locator("#wf-viewport .wf-node")

module.exports = { center, drag, addBlock, block, port, connect, newWorkflow, edges, nodes }
