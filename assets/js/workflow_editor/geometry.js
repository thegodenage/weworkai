// Where arrows run: port points on a block's sides and the bezier curves between them.

export const SIDES = ["top", "right", "bottom", "left"]

const DIRECTIONS = {top: {x: 0, y: -1}, right: {x: 1, y: 0}, bottom: {x: 0, y: 1}, left: {x: -1, y: 0}}

// `shift` moves the point along its side, off the middle (arrows sharing a dot).
export function portPoint(box, side, shift = 0) {
  const {x, y, width, height} = box
  switch (side) {
    case "top":
      return {x: x + width / 2 + shift, y}
    case "right":
      return {x: x + width, y: y + height / 2 + shift}
    case "bottom":
      return {x: x + width / 2 + shift, y: y + height}
    default:
      return {x, y: y + height / 2 + shift}
  }
}

const horizontal = (side) => side === "top" || side === "bottom"

// Arrows that meet on one dot fan out along its side, each placed in the order of where its
// other end lies, so they neither overlap nor cross there. `ends` are {key, side, length,
// toward: the other end's point}; the answer maps each key to its shift.
export function spread(ends) {
  const bySide = new Map()
  for (const end of ends) bySide.set(end.dot, [...(bySide.get(end.dot) || []), end])
  const shifts = new Map()
  for (const group of bySide.values()) {
    if (group.length === 1) {
      shifts.set(group[0].key, 0)
      continue
    }
    const along = (end) => (horizontal(end.side) ? end.toward.x : end.toward.y)
    const gap = Math.min(28, (group[0].length - 24) / (group.length - 1))
    ;[...group]
      .sort((a, b) => along(a) - along(b))
      .forEach((end, index) => shifts.set(end.key, (index - (group.length - 1) / 2) * gap))
  }
  return shifts
}

export function nearestSide(box, point) {
  const distance = (side) => Math.hypot(portPoint(box, side).x - point.x, portPoint(box, side).y - point.y)
  return SIDES.reduce((best, side) => (distance(side) < distance(best) ? side : best))
}

// The side of the box that faces a point: where an arrow from there should come in.
export function facingSide(box, point) {
  const dx = (point.x - (box.x + box.width / 2)) / box.width
  const dy = (point.y - (box.y + box.height / 2)) / box.height
  if (Math.abs(dx) > Math.abs(dy)) return dx > 0 ? "right" : "left"
  return dy > 0 ? "bottom" : "top"
}

// The side a free end (the pointer) comes in from, so a preview curve bends naturally.
function sideFacing(from, to) {
  const dx = to.x - from.x
  const dy = to.y - from.y
  if (Math.abs(dx) > Math.abs(dy)) return dx > 0 ? "left" : "right"
  return dy > 0 ? "top" : "bottom"
}

const at = (a, b, c, d, t) => {
  const u = 1 - t
  return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d
}

export function curve(start, startSide, end, endSide = sideFacing(start, end)) {
  const reach = Math.min(160, Math.max(40, Math.hypot(end.x - start.x, end.y - start.y) * 0.45))
  const out = DIRECTIONS[startSide]
  const back = DIRECTIONS[endSide]
  const c1 = {x: start.x + out.x * reach, y: start.y + out.y * reach}
  const c2 = {x: end.x + back.x * reach, y: end.y + back.y * reach}
  return {
    d: `M ${start.x} ${start.y} C ${c1.x} ${c1.y}, ${c2.x} ${c2.y}, ${end.x} ${end.y}`,
    mid: {x: at(start.x, c1.x, c2.x, end.x, 0.5), y: at(start.y, c1.y, c2.y, end.y, 0.5)},
  }
}

// A self-loop: out of the side and back into it a little further along.
export function loop(box, side) {
  const anchor = portPoint(box, side)
  const out = DIRECTIONS[side]
  const along = {x: Math.abs(out.y), y: Math.abs(out.x)}
  const spread = 16
  const reach = 70
  const start = {x: anchor.x - along.x * spread, y: anchor.y - along.y * spread}
  const end = {x: anchor.x + along.x * spread, y: anchor.y + along.y * spread}
  const c1 = {x: start.x + out.x * reach - along.x * 36, y: start.y + out.y * reach - along.y * 36}
  const c2 = {x: end.x + out.x * reach + along.x * 36, y: end.y + out.y * reach + along.y * 36}
  return {
    d: `M ${start.x} ${start.y} C ${c1.x} ${c1.y}, ${c2.x} ${c2.y}, ${end.x} ${end.y}`,
    mid: {x: at(start.x, c1.x, c2.x, end.x, 0.5), y: at(start.y, c1.y, c2.y, end.y, 0.5)},
    start,
    end,
  }
}
