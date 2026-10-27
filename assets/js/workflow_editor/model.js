// The editor's graph: plain data, changed only by the pure functions below, each returning
// a new graph. Its shape is what the server's Graph.validate/2 takes (nodes with x / y,
// edges naming their ends `from` / `to`), so saving sends it as it is.
import {facingSide} from "./geometry.js"

export const GRID = 20
export const BLOCK = {width: 220, height: 64}
export const GROUP = {width: 380, height: 220, header: 40, padding: 24}
const MIN_GROUP = {width: 240, height: 140}

export const snap = (value) => Math.round(value / GRID) * GRID

let counter = 0
export const newId = (prefix) => `${prefix}${Date.now().toString(36)}${(counter++).toString(36)}`

export function fromServer({nodes, edges}) {
  return {
    nodes: nodes.map((node) => ({...node, ...sizeFields(node)})),
    edges: edges.map((edge) => ({pinned: false, ...edge})),
  }
}

function sizeFields(node) {
  if (node.kind !== "group") return {width: null, height: null}
  return {width: node.width || GROUP.width, height: node.height || GROUP.height}
}

export const isGroup = (node) => node.kind === "group"
export const findNode = (graph, id) => graph.nodes.find((node) => node.id === id)
export const findEdge = (graph, id) => graph.edges.find((edge) => edge.id === id)

export function rect(node) {
  const {width, height} = isGroup(node) ? node : BLOCK
  return {x: node.x, y: node.y, width, height}
}

const area = (node) => rect(node).width * rect(node).height
const center = (node) => {
  const {x, y, width, height} = rect(node)
  return {x: x + width / 2, y: y + height / 2}
}
const inside = (point, box) =>
  point.x >= box.x && point.x <= box.x + box.width && point.y >= box.y && point.y <= box.y + box.height

export function children(graph, groupId) {
  return graph.nodes.filter((node) => node.group_id === groupId)
}

// The group's blocks and groups, all the way down.
export function descendants(graph, groupId) {
  return children(graph, groupId).flatMap((child) => [child.id, ...descendants(graph, child.id)])
}

// Selected ids plus everything inside the selected groups: what a drag or a copy takes along.
export function withContents(graph, ids) {
  return [...new Set(ids.flatMap((id) => [id, ...descendants(graph, id)]))]
}

export function depth(graph, node) {
  const parent = node.group_id && findNode(graph, node.group_id)
  return parent ? 1 + depth(graph, parent) : 0
}

export function bounds(nodes) {
  if (nodes.length === 0) return null
  const boxes = nodes.map(rect)
  const x = Math.min(...boxes.map((box) => box.x))
  const y = Math.min(...boxes.map((box) => box.y))
  const right = Math.max(...boxes.map((box) => box.x + box.width))
  const bottom = Math.max(...boxes.map((box) => box.y + box.height))
  return {x, y, width: right - x, height: bottom - y}
}

// A block belongs to the smallest group its centre lies in: what is drawn inside a group is
// in it. A group can only sit in a larger one, so membership never loops.
export function assignGroups(graph) {
  const groups = graph.nodes.filter(isGroup)
  const nodes = graph.nodes.map((node) => {
    const home = groups
      .filter((group) => group.id !== node.id && area(group) > area(node))
      .filter((group) => inside(center(node), rect(group)))
      .sort((a, b) => area(a) - area(b))[0]
    const groupId = home ? home.id : null
    return node.group_id === groupId ? node : {...node, group_id: groupId}
  })
  return {...graph, nodes}
}

// After a drop: a group grows (never shrinks) to hold its blocks with room around them,
// innermost first so the groups around it grow with it.
export function fitGroups(graph) {
  const groups = graph.nodes.filter(isGroup).sort((a, b) => depth(graph, b) - depth(graph, a))
  const grown = []
  const fitted = groups.reduce((current, group) => {
    const box = bounds(children(current, group.id))
    if (!box) return current
    const own = findNode(current, group.id)
    const x = Math.min(own.x, snap(box.x - GROUP.padding))
    const y = Math.min(own.y, snap(box.y - GROUP.header - GROUP.padding / 2))
    const right = Math.max(own.x + own.width, snap(box.x + box.width + GROUP.padding))
    const bottom = Math.max(own.y + own.height, snap(box.y + box.height + GROUP.padding))
    if (x === own.x && y === own.y && right === own.x + own.width && bottom === own.y + own.height) return current
    grown.push(group.id)
    return updateNode(current, group.id, {x, y, width: right - x, height: bottom - y})
  }, graph)
  return fitted === graph ? graph : reroute(assignGroups(fitted), grown)
}

export function addNode(graph, node) {
  const first = graph.nodes.length === 0
  return assignGroups({...graph, nodes: [...graph.nodes, {...node, start: first}]})
}

export function updateNode(graph, id, changes) {
  return {...graph, nodes: graph.nodes.map((node) => (node.id === id ? {...node, ...changes} : node))}
}

export function updateEdge(graph, id, changes) {
  return {...graph, edges: graph.edges.map((edge) => (edge.id === id ? {...edge, ...changes} : edge))}
}

// Positions are absolute, so moving a group moves the blocks inside it by the same amount.
export function moveNodes(graph, origins, dx, dy) {
  const moved = {
    ...graph,
    nodes: graph.nodes.map((node) => {
      const origin = origins[node.id]
      return origin ? {...node, x: snap(origin.x + dx), y: snap(origin.y + dy)} : node
    }),
  }
  return reroute(moved, Object.keys(origins))
}

export function resizeGroup(graph, id, origin, dx, dy) {
  const resized = updateNode(graph, id, {
    width: Math.max(MIN_GROUP.width, snap(origin.width + dx)),
    height: Math.max(MIN_GROUP.height, snap(origin.height + dy)),
  })
  return reroute(resized, [id])
}

// Moves the nodes by a few pixels off the grid (snapping to a neighbour's edge or centre).
export function nudgeNodes(graph, ids, dx, dy) {
  if (!dx && !dy) return graph
  const moving = new Set(ids)
  const nodes = graph.nodes.map((node) => (moving.has(node.id) ? {...node, x: node.x + dx, y: node.y + dy} : node))
  return reroute({...graph, nodes}, ids)
}

// The arrows of the blocks that moved run between the sides their two blocks face each
// other with, unless their dots were chosen by hand (`pinned`: an end dragged onto a dot).
// Loops, and arrows between a group and a block inside it, keep theirs.
export function reroute(graph, ids) {
  const moved = new Set(ids)
  let changed = false
  const edges = graph.edges.map((edge) => {
    if (edge.pinned || edge.from === edge.to || !(moved.has(edge.from) || moved.has(edge.to))) return edge
    const from = findNode(graph, edge.from)
    const to = findNode(graph, edge.to)
    if (!from || !to || contains(rect(from), rect(to)) || contains(rect(to), rect(from))) return edge
    const ports = {from_port: facingSide(rect(from), center(to)), to_port: facingSide(rect(to), center(from))}
    if (ports.from_port === edge.from_port && ports.to_port === edge.to_port) return edge
    changed = true
    return {...edge, ...ports}
  })
  return changed ? {...graph, edges} : graph
}

const contains = (outer, inner) =>
  inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.width <= outer.x + outer.width && inner.y + inner.height <= outer.y + outer.height

export function setStart(graph, id) {
  return {...graph, nodes: graph.nodes.map((node) => ({...node, start: node.id === id}))}
}

// The block tasks begin on: the one marked, else the only top-level block no arrow enters
// (as the server decides it).
export function startId(graph) {
  const marked = graph.nodes.find((node) => node.start)
  if (marked) return marked.id
  const entered = new Set(graph.edges.filter((edge) => edge.from !== edge.to).map((edge) => edge.to))
  const candidates = graph.nodes.filter((node) => !node.group_id && !entered.has(node.id))
  return candidates.length === 1 ? candidates[0].id : null
}

export function connect(graph, {from, to, fromPort, toPort}) {
  const loop = from === to
  const edge = {
    id: newId("e"),
    from,
    to,
    condition: null,
    iterations: loop ? 2 : null,
    from_port: fromPort,
    to_port: loop ? fromPort : toPort,
    pinned: false,
  }
  return {graph: {...graph, edges: [...graph.edges, edge]}, edge}
}

// Removing a group keeps its blocks: they fall into the group around it, if any.
export function remove(graph, {nodes, edges}) {
  const gone = new Set(nodes)
  const goneEdges = new Set(edges)
  return assignGroups({
    nodes: graph.nodes.filter((node) => !gone.has(node.id)),
    edges: graph.edges.filter(
      (edge) => !goneEdges.has(edge.id) && !gone.has(edge.from) && !gone.has(edge.to),
    ),
  })
}

export function group(graph, ids, label) {
  const members = graph.nodes.filter((node) => ids.includes(node.id))
  const box = bounds(members)
  const node = {
    id: newId("g"),
    kind: "group",
    label,
    employee_id: null,
    agent_role: null,
    column_status: null,
    group_id: null,
    color: "blue",
    prompt: null,
    stall_timeout_minutes: null,
    turn_timeout_minutes: null,
    start: false,
    x: snap(box.x - GROUP.padding),
    y: snap(box.y - GROUP.header - GROUP.padding / 2),
    width: snap(box.width + GROUP.padding * 2),
    height: snap(box.height + GROUP.header + GROUP.padding * 1.5),
  }
  return {graph: assignGroups({...graph, nodes: [...graph.nodes, node]}), group: node}
}

export function ungroup(graph, id) {
  return remove(graph, {nodes: [id], edges: []})
}

// Copies of the nodes (groups with their contents) and the arrows between them, shifted.
export function duplicate(graph, source, offset) {
  const ids = new Map(source.nodes.map((node) => [node.id, newId(isGroup(node) ? "g" : "n")]))
  const nodes = source.nodes.map((node) => ({
    ...node,
    id: ids.get(node.id),
    group_id: ids.get(node.group_id) || node.group_id,
    start: false,
    x: node.x + offset,
    y: node.y + offset,
  }))
  const edges = source.edges
    .filter((edge) => ids.has(edge.from) && ids.has(edge.to))
    .map((edge) => ({...edge, id: newId("e"), from: ids.get(edge.from), to: ids.get(edge.to)}))
  return {
    graph: assignGroups({nodes: [...graph.nodes, ...nodes], edges: [...graph.edges, ...edges]}),
    ids: nodes.map((node) => node.id),
  }
}

export function subgraph(graph, ids) {
  const taken = new Set(withContents(graph, ids))
  return {
    nodes: graph.nodes.filter((node) => taken.has(node.id)),
    edges: graph.edges.filter((edge) => taken.has(edge.from) && taken.has(edge.to)),
  }
}

// After a save: the server's ids for the editor's own.
export function remap(graph, ids) {
  const id = (value) => (value && ids[value]) || value
  return {
    nodes: graph.nodes.map((node) => ({...node, id: id(node.id), group_id: id(node.group_id)})),
    edges: graph.edges.map((edge) => ({...edge, id: id(edge.id), from: id(edge.from), to: id(edge.to)})),
  }
}

export function toServer(graph) {
  return {
    nodes: graph.nodes.map((node) => ({
      ...node,
      x: Math.round(node.x),
      y: Math.round(node.y),
      width: isGroup(node) ? Math.round(node.width) : null,
      height: isGroup(node) ? Math.round(node.height) : null,
    })),
    edges: graph.edges,
  }
}

// Equal for graphs that would save the same, whatever order things were added in.
export function fingerprint(graph) {
  const byId = (a, b) => (a.id < b.id ? -1 : 1)
  const {nodes, edges} = toServer(graph)
  return JSON.stringify({nodes: [...nodes].sort(byId), edges: [...edges].sort(byId)})
}
