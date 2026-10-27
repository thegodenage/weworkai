// Draws the graph: absolutely positioned HTML blocks and groups, one SVG for the arrows and
// HTML pills for their labels. Blocks and groups are kept by id between draws (so focus and
// hover survive); arrows are cheap and redrawn whole.
import {el, icon, svg} from "./dom.js"
import {SIDES, curve, loop, portPoint, spread} from "./geometry.js"
import {depth, isGroup, rect, startId, findNode, descendants} from "./model.js"

const MARKERS = ["default", "selected", "error", "preview"]

export function createRenderer(layers) {
  const elements = new Map()

  layers.edges.append(defs())

  function draw(view) {
    const {graph} = view
    const start = startId(graph)
    const seen = new Set()

    for (const node of graph.nodes) {
      seen.add(node.id)
      const element = elements.get(node.id) || create(node)
      if (isGroup(node)) drawGroup(element, node, view, start)
      else drawBlock(element, node, view, start)
    }

    for (const [id, element] of elements) {
      if (!seen.has(id)) {
        element.remove()
        elements.delete(id)
      }
    }

    drawEdges(view)
  }

  function create(node) {
    const element = isGroup(node)
      ? el("div", {class: "wf-group", id: `wf-node-${node.id}`, dataset: {nodeId: node.id, kind: "group"}})
      : el("div", {class: "wf-node", id: `wf-node-${node.id}`, tabindex: "0", role: "button", dataset: {nodeId: node.id}})
    ;(isGroup(node) ? layers.groups : layers.nodes).append(element)
    elements.set(node.id, element)
    return element
  }

  function drawBlock(element, node, view, start) {
    const info = view.catalog.describe(node)
    const problems = view.problems.get(node.id) || []
    const signature = JSON.stringify([node.label, info, node.id === start, problems, node.kind, node.prompt])

    element.style.transform = `translate(${node.x}px, ${node.y}px)`
    element.dataset.kind = node.kind
    element.className = ["wf-node", `tone-${info.tone}`, classes(node, view, problems)].join(" ")
    element.setAttribute(
      "aria-label",
      `${view.catalog.kindLabel(node)} block ${node.label}, ${info.subtitle}${node.prompt ? ", has its own instructions" : ""}${node.id === start ? ", start" : ""}`,
    )
    element.setAttribute("aria-pressed", view.selection.nodes.has(node.id) ? "true" : "false")

    if (element.dataset.signature === signature) return
    element.dataset.signature = signature
    element.replaceChildren(
      ...present(
      info.avatar ? el("span", {class: "wf-avatar", text: info.avatar}) : el("span", {class: "wf-avatar wf-avatar-icon"}, icon(info.icon, "size-4")),
      el("span", {class: "wf-node-text"}, [
        el("span", {class: "wf-node-label", dataset: {label: ""}, text: node.label}),
        el("span", {class: "wf-node-subtitle", text: info.subtitle}),
      ]),
      node.prompt ? promptMark(node.prompt) : null,
      node.id === start ? startFlag() : null,
      problems.length ? problemBadge(problems) : null,
      ...portsOf(element, node),
      ),
    )
  }

  // The same dot elements across redraws (a validation reply redraws a block's badge), so
  // a pointer on a dot, or anything holding one, never finds it swapped.
  function portsOf(element, node) {
    element.wfPorts ||= ports(node)
    return element.wfPorts
  }

  function drawGroup(element, node, view, start) {
    const problems = view.problems.get(node.id) || []
    const count = descendants(view.graph, node.id).filter((id) => !isGroup(findNode(view.graph, id))).length
    const signature = JSON.stringify([node.label, count, node.id === start, problems])

    element.style.transform = `translate(${node.x}px, ${node.y}px)`
    element.style.width = `${node.width}px`
    element.style.height = `${node.height}px`
    element.style.zIndex = String(depth(view.graph, node))
    element.className = ["wf-group", `wf-color-${node.color || "blue"}`, classes(node, view, problems)].join(" ")

    if (element.dataset.signature === signature) return
    element.dataset.signature = signature
    element.replaceChildren(
      el(
        "div",
        {
          class: "wf-group-header",
          tabindex: "0",
          role: "button",
          dataset: {groupHeader: ""},
          "aria-label": `Group ${node.label}, ${count} blocks${node.id === start ? ", start" : ""}`,
        },
        [
          icon("hero-rectangle-group-micro", "size-3.5"),
          el("span", {class: "wf-group-label", dataset: {label: ""}, text: node.label}),
          el("span", {class: "wf-group-count", text: `${count} ${count === 1 ? "block" : "blocks"}`}),
          node.id === start ? startFlag() : null,
          problems.length ? problemBadge(problems) : null,
        ],
      ),
      el("span", {class: "wf-resize", dataset: {resize: ""}, title: "Drag to resize", "aria-hidden": "true"}),
      ...portsOf(element, node),
    )
  }

  function drawEdges(view) {
    const {graph, selection, problems} = view
    const paths = []
    const labels = []
    const shifts = endShifts(graph)
    // Placed once they are in the page, where their real widths can be measured.
    const pills = []

    for (const edge of graph.edges) {
      const from = findNode(graph, edge.from)
      const to = findNode(graph, edge.to)
      if (!from || !to) continue
      const shape = shapeOf(edge, from, to, shifts)
      const selected = selection.edges.has(edge.id)
      const errors = problems.get(edge.id) || []
      const state = errors.length ? "error" : selected ? "selected" : "default"

      const group = svg("g", {
        class: ["wf-edge", selected && "is-selected", errors.length && "has-error"].filter(Boolean).join(" "),
        id: `wf-edge-${edge.id}`,
        "data-edge-id": edge.id,
        "data-from": edge.from,
        "data-to": edge.to,
        "data-from-port": edge.from_port,
        "data-to-port": edge.to_port,
        "data-pinned": edge.pinned ? "true" : null,
      })
      group.append(
        svg("path", {class: "wf-edge-hit", d: shape.d}),
        svg("path", {class: "wf-edge-line", d: shape.d, "marker-end": `url(#wf-arrow-${state})`}),
      )
      paths.push(group)
      // Above the blocks (HTML, in the labels layer): a handle sits on a block's dot.
      if (selected) {
        for (const [end, point] of [["from", shape.start], ["to", shape.end]]) {
          labels.push(
            el("span", {
              class: "wf-edge-handle",
              dataset: {edgeHandle: end, edgeId: edge.id},
              style: `transform: translate(${point.x}px, ${point.y}px) translate(-50%, -50%)`,
              title: "Drag onto another dot to re-attach",
            }),
          )
        }
      }

      const text = labelText(edge, from, view.catalog)
      if (text || errors.length || selected) {
        const label = el(
          "button",
          {
            type: "button",
            class: ["wf-edge-label", selected && "is-selected", errors.length && "has-error", !text && "is-empty"]
              .filter(Boolean)
              .join(" "),
            id: `wf-edge-label-${edge.id}`,
            dataset: {edgeId: edge.id},
            title: errors.length ? errors.join("\n") : `${from.label} → ${to.label}`,
            "aria-label": `Arrow ${from.label} to ${to.label}${text ? `: ${text}` : ""}`,
          },
          [errors.length ? icon("hero-exclamation-circle-micro", "size-3") : null, text || "always"],
        )
        const remover = selected
          ? el(
              "button",
              {
                type: "button",
                class: "wf-edge-delete",
                id: `wf-edge-delete-${edge.id}`,
                dataset: {edgeDelete: edge.id},
                title: "Delete this arrow (⌫)",
                "aria-label": `Delete the arrow ${from.label} to ${to.label}`,
              },
              [icon("hero-x-mark-micro", "size-3")],
            )
          : null
        labels.push(...present(label, remover))
        pills.push({label, remover, mid: shape.mid})
      }
    }

    if (view.preview) {
      paths.push(svg("path", {class: "wf-edge-preview", d: view.preview.d, "marker-end": "url(#wf-arrow-preview)"}))
    }

    // Labels are drawn afresh: one that had the focus (a keyboard user on an arrow) gets it back.
    const focused = layers.labels.contains(document.activeElement) ? document.activeElement.id : null
    layers.edges.replaceChildren(layers.edges.firstChild, ...paths)
    layers.labels.replaceChildren(...labels)
    place(pills)
    if (focused) document.getElementById(focused)?.focus({preventScroll: true})
  }

  return {draw, element: (id) => elements.get(id)}
}

export function shapeOf(edge, from, to, shifts = new Map()) {
  if (edge.from === edge.to) return loop(rect(from), edge.from_port)
  const start = portPoint(rect(from), edge.from_port, shifts.get(`${edge.id}:from`))
  const end = portPoint(rect(to), edge.to_port, shifts.get(`${edge.id}:to`))
  return {...curve(start, edge.from_port, end, edge.to_port), start, end}
}

// Both ends of every arrow but loops, on the dot they meet (block and side).
function endShifts(graph) {
  const ends = graph.edges.flatMap((edge) => {
    const from = findNode(graph, edge.from)
    const to = findNode(graph, edge.to)
    if (!from || !to || edge.from === edge.to) return []
    const end = (key, node, side, other, otherSide) => {
      const box = rect(node)
      return {
        key: `${edge.id}:${key}`,
        dot: `${node.id}:${side}`,
        side,
        length: side === "top" || side === "bottom" ? box.width : box.height,
        toward: portPoint(rect(other), otherSide),
      }
    }
    return [end("from", from, edge.from_port, to, edge.to_port), end("to", to, edge.to_port, from, edge.from_port)]
  })
  return spread(ends)
}

// Where labels go: their curve's middle, or off it, below then above, when another label
// is there already; the selected one's × sits on its top right corner. Sizes are measured
// (layout size, before the camera's scale: world units), so a long label or a zoomed font
// moves the others as far as it needs.
const LABEL_GAP = 4

function place(pills) {
  const measured = pills.map((pill) => ({
    ...pill,
    width: pill.label.offsetWidth,
    height: pill.label.offsetHeight,
    removerSize: pill.remover ? pill.remover.offsetWidth : 0,
  }))
  const placed = []
  for (const pill of measured) {
    const spot = clear(pill, placed)
    pill.label.style.transform = `translate(${spot.x}px, ${spot.y}px) translate(-50%, -50%)`
    if (pill.remover) {
      const size = pill.removerSize
      pill.remover.style.transform = `translate(${spot.x + pill.width / 2 - size / 2}px, ${spot.y - pill.height / 2 - size / 2 - 2}px)`
    }
  }
}

function clear({mid, width, height}, placed) {
  const hits = (spot) =>
    placed.some((other) => Math.abs(other.x - spot.x) < (other.width + width) / 2 + LABEL_GAP && Math.abs(other.y - spot.y) < (other.height + height) / 2 + LABEL_GAP / 2)
  let spot = {...mid, width, height}
  for (let step = 1; step <= 6 && hits(spot); step++) {
    spot = {...mid, width, height, y: mid.y + (step % 2 ? 1 : -1) * Math.ceil(step / 2) * (height + LABEL_GAP)}
  }
  placed.push(spot)
  return spot
}

export function labelText(edge, from, catalog) {
  const loopy = edge.from === edge.to
  const parts = []
  if (edge.condition) parts.push(edge.condition)
  if (edge.iterations) parts.push(loopy ? `×${edge.iterations}` : `max ${edge.iterations}`)
  if (!edge.condition && from.kind === "human") parts.unshift("name this decision")
  return parts.join(" · ")
}

// replaceChildren would write a null as the text "null".
const present = (...children) => children.filter(Boolean)

function classes(node, view, problems) {
  return [
    view.selection.nodes.has(node.id) && "is-selected",
    problems.length && "has-error",
    view.dropTarget === node.id && "is-drop-target",
    view.connecting && "is-connecting",
  ]
    .filter(Boolean)
    .join(" ")
}

function ports(node) {
  return SIDES.map((side) =>
    el("span", {
      class: `wf-port wf-port-${side}`,
      dataset: {port: side, nodeId: node.id},
      title: "Drag to another block to connect, or drop a new block here",
      "aria-hidden": "true",
    }),
  )
}

const PREVIEW = 280

function promptMark(prompt) {
  const preview = prompt.length > PREVIEW ? `${prompt.slice(0, PREVIEW)}…` : prompt
  return el("span", {class: "wf-prompt-mark", dataset: {promptMark: ""}, title: `Its own instructions:\n${preview}`}, [
    icon("hero-chat-bubble-bottom-center-text-micro", "size-3.5"),
  ])
}

function startFlag() {
  return el("span", {class: "wf-start", title: "Tasks start here"}, [icon("hero-play-micro", "size-3"), "Start"])
}

function problemBadge(problems) {
  return el("span", {class: "wf-problem", title: problems.join("\n"), "aria-label": `${problems.length} problems: ${problems.join(" ")}`}, [
    icon("hero-exclamation-circle-micro", "size-3.5"),
    problems.length > 1 ? String(problems.length) : null,
  ])
}

function defs() {
  const defs = svg("defs")
  for (const state of MARKERS) {
    const marker = svg("marker", {
      id: `wf-arrow-${state}`,
      viewBox: "0 0 10 10",
      refX: "8.5",
      refY: "5",
      markerWidth: "12",
      markerHeight: "12",
      markerUnits: "userSpaceOnUse",
      orient: "auto-start-reverse",
    })
    marker.append(svg("path", {d: "M 0 1 L 9 5 L 0 9 z", class: `wf-arrowhead wf-arrowhead-${state}`}))
    defs.append(marker)
  }
  return defs
}
