// The editor itself: owns the graph being edited, the selection and the camera, turns
// pointer and keyboard input into model changes, and talks to WorkflowLive ("validate",
// "save"). Every change goes through `commit` (undoable) or `preview` (mid-drag, not yet).
import {el, svg, typing} from "./dom.js"
import {createCatalog} from "./catalog.js"
import {clearDraft, readDraft, writeDraft} from "./drafts.js"
import {createHistory} from "./history.js"
import {renderInspector} from "./inspector.js"
import {createRenderer, shapeOf} from "./render.js"
import {curve, facingSide, nearestSide, portPoint} from "./geometry.js"
import {
  BLOCK,
  GRID,
  GROUP,
  addNode,
  assignGroups,
  bounds,
  connect,
  duplicate,
  findEdge,
  findNode,
  fingerprint,
  fitGroups,
  fromServer,
  group,
  isGroup,
  moveNodes,
  newId,
  nudgeNodes,
  rect,
  remap,
  remove,
  reroute,
  resizeGroup,
  setStart,
  snap,
  subgraph,
  toServer,
  ungroup,
  updateEdge,
  updateNode,
  withContents,
} from "./model.js"

const ZOOM = {min: 0.2, max: 2.5}
const DRAG_THRESHOLD = 4
const VALIDATE_MS = 350
const LEAVE_WARNING = "Leave without saving? Your changes to this workflow will be lost."

const problemsById = (list) =>
  list.reduce((map, {id, message}) => map.set(id ?? null, [...(map.get(id ?? null) || []), message]), new Map())

const clamp = (value, min, max) => Math.min(max, Math.max(min, value))

export function createEditor(hook) {
  const root = hook.el
  const $ = (selector) => root.querySelector(selector)
  const viewport = $("#wf-viewport")
  const world = viewport.querySelector("[data-world]")
  const rubber = viewport.querySelector("[data-rubber]")
  const guides = viewport.querySelector("[data-guides]")
  const menu = viewport.querySelector("[data-menu]")
  const quick = viewport.querySelector("[data-quick]")
  const inspector = $("#wf-inspector")
  const palette = $("#wf-palette")
  const renderer = createRenderer({
    groups: world.querySelector("[data-groups]"),
    nodes: world.querySelector("[data-nodes]"),
    edges: world.querySelector("[data-edges]"),
    labels: world.querySelector("[data-labels]"),
  })

  const catalog = createCatalog(JSON.parse(root.dataset.catalog))
  const workflowId = root.dataset.workflowId
  let graph = fromServer(JSON.parse(root.dataset.graph))
  const history = createHistory(graph)
  let saved = fingerprint(graph)
  // The stored version this graph was drawn from: a save over a newer one is refused.
  let version = Number(root.dataset.version)
  let problems = problemsById(JSON.parse(root.dataset.problems))
  let selection = {nodes: new Set(), edges: new Set()}
  let camera = {x: 0, y: 0, zoom: 1}
  let gesture = null
  let previewPath = null
  let dropTarget = null
  let clipboard = null
  let pastes = 0
  let spaceHeld = false
  let pointerActive = false
  let suppressClick = false
  let saving = false
  let validation = {timer: null, sequence: 0}
  let frame = null
  // Set once the person agreed to leave, so the page asks once, not again on unload.
  let leaving = false
  const banner = $("#wf-banner")

  // Drawing

  const view = () => ({
    graph,
    selection,
    problems,
    catalog,
    preview: previewPath,
    dropTarget,
    connecting: gesture && (gesture.type === "connect" || gesture.type === "reattach"),
  })

  // The canvas redraws once a frame. The inspector redraws at once when the selection
  // changed, so a quick edit never lands on the item selected before; else with the canvas,
  // once a Tab out of an edited field has moved focus (which it then keeps, by id).
  let shownSelection = null
  let panelStale = false

  function refresh({panel = true} = {}) {
    const selected = [...selection.nodes, "|", ...selection.edges].join(" ")
    if (panel && selected !== shownSelection) {
      shownSelection = selected
      panelStale = false
      renderInspector(inspector, view(), actions)
    } else if (panel) panelStale = true
    if (frame) return
    frame = requestAnimationFrame(() => {
      frame = null
      renderer.draw(view())
      applyCamera()
      chrome()
      if (panelStale) {
        panelStale = false
        renderInspector(inspector, view(), actions)
      }
    })
  }

  function applyCamera() {
    world.style.transform = `translate(${camera.x}px, ${camera.y}px) scale(${camera.zoom})`
    viewport.style.backgroundSize = `${GRID * camera.zoom}px ${GRID * camera.zoom}px`
    viewport.style.backgroundPosition = `${camera.x}px ${camera.y}px`
    $("#wf-zoom-reset").textContent = `${Math.round(camera.zoom * 100)}%`
  }

  const dirty = () => fingerprint(graph) !== saved
  const problemCount = () => [...problems.values()].reduce((sum, list) => sum + list.length, 0)

  function chrome() {
    const isDirty = dirty()
    $("#wf-dirty").classList.toggle("hidden", !isDirty)
    $("#wf-dirty").classList.toggle("flex", isDirty)
    $("#wf-save").disabled = saving || !isDirty
    $("#wf-save").title = problemCount() && graph.nodes.length
      ? "Save as a draft (⌘S): tasks can't run it until its problems are fixed"
      : "Save (⌘S)"
    $("#wf-undo").disabled = !history.canUndo
    $("#wf-redo").disabled = !history.canRedo
    $("#wf-group").disabled = selection.nodes.size === 0
    $("#wf-ungroup").disabled = !selectedGroups().length
    $("#wf-duplicate").disabled = selection.nodes.size === 0
    $("#wf-delete").disabled = selection.nodes.size + selection.edges.size === 0
    $("#wf-empty").classList.toggle("hidden", graph.nodes.length > 0)
    $("#wf-empty").classList.toggle("flex", graph.nodes.length === 0)
    // An empty canvas has its hint; its one problem ("Add a first block") needs no badge.
    const count = graph.nodes.length ? problemCount() : 0
    const badge = $("#wf-problem-count")
    badge.classList.toggle("hidden", count === 0)
    badge.classList.toggle("inline-flex", count > 0)
    badge.querySelector("[data-count]").textContent = `${count} ${count === 1 ? "problem" : "problems"}`
    viewport.classList.toggle("is-space", spaceHeld)
  }

  // Changing the graph

  function commit(next, {select} = {}) {
    history.push(next)
    graph = next
    if (select) selection = {nodes: new Set(select.nodes || []), edges: new Set(select.edges || [])}
    pruneSelection()
    changed()
  }

  function changed() {
    leaving = false
    if (!saving) setSaveLabel("Save")
    if (banner.dataset.kind === "draft") hideBanner()
    keepDraft()
    refresh()
    scheduleValidation()
  }

  function keepDraft() {
    if (dirty()) writeDraft(workflowId, {graph: toServer(graph), version, at: Date.now()})
    else clearDraft(workflowId)
  }

  function preview(next) {
    graph = next
    refresh({panel: false})
  }

  // Undo / redo select what they bring back (deleted blocks, else arrows: a block's own
  // come back with it), else keep what still exists of the selection.
  function restore(next) {
    if (!next) return
    const nodes = next.nodes.filter((node) => !findNode(graph, node.id)).map((node) => node.id)
    const edges = next.edges.filter((edge) => !findEdge(graph, edge.id)).map((edge) => edge.id)
    graph = next
    if (nodes.length) selection = {nodes: new Set(nodes), edges: new Set()}
    else if (edges.length) selection = {nodes: new Set(), edges: new Set(edges)}
    pruneSelection()
    changed()
  }

  function pruneSelection() {
    selection = {
      nodes: new Set([...selection.nodes].filter((id) => findNode(graph, id))),
      edges: new Set([...selection.edges].filter((id) => findEdge(graph, id))),
    }
  }

  function select({nodes = [], edges = []} = {}) {
    selection = {nodes: new Set(nodes), edges: new Set(edges)}
    refresh()
  }

  function toggle(kind, id) {
    const next = new Set(selection[kind])
    next.has(id) ? next.delete(id) : next.add(id)
    selection = {...selection, [kind]: next}
    refresh()
  }

  const selectedGroups = () => [...selection.nodes].filter((id) => isGroup(findNode(graph, id) || {}))

  // The server checks every draft, so problems show while editing, not only on save.
  function scheduleValidation() {
    clearTimeout(validation.timer)
    validation.timer = setTimeout(() => {
      const sequence = ++validation.sequence
      hook.pushEvent("validate", toServer(graph), (reply) => {
        if (sequence !== validation.sequence) return
        problems = problemsById(reply.problems)
        refresh()
      })
    }, VALIDATE_MS)
  }

  // A graph with problems saves too (the workflow then runs no task until they are fixed);
  // only one that can't be stored at all, or one drawn from an older version, is refused.
  function save() {
    if (saving) return
    saving = true
    clearTimeout(validation.timer)
    validation.sequence++
    const sent = graph
    setSaveLabel("Saving…")
    chrome()
    hook.pushEvent("save", {...toServer(sent), version}, (reply) => {
      saving = false
      if (reply.ok) {
        const rename = (one) => remap(one, reply.ids)
        history.map(rename)
        graph = rename(graph)
        saved = fingerprint(rename(sent))
        version = reply.version
        selection = {
          nodes: new Set([...selection.nodes].map((id) => reply.ids[id] || id)),
          edges: new Set([...selection.edges].map((id) => reply.ids[id] || id)),
        }
        problems = problemsById(reply.problems)
        hideBanner()
        keepDraft()
        setSaveLabel(reply.problems.length ? "Saved as draft" : "Saved", 2400)
        if (dirty()) scheduleValidation()
      } else if (reply.stale) {
        setSaveLabel("Save")
        showStale(reply.version)
      } else {
        problems = problemsById(reply.problems)
        selection = {nodes: new Set(), edges: new Set()}
        setSaveLabel("Save")
        root.dataset.saveFailed = String(Date.now())
      }
      refresh()
    })
  }

  // Banners over the canvas: unsaved changes from before a reload, or a save refused
  // because the workflow was saved elsewhere meanwhile.

  function showBanner(kind, text, buttons) {
    banner.dataset.kind = kind
    banner.replaceChildren(
      el("span", {class: "wf-banner-text", text}),
      ...buttons.map(([id, label, run, primary]) =>
        el("button", {type: "button", id, class: `btn btn-xs ${primary ? "btn-primary" : "btn-ghost"}`, onclick: run}, label),
      ),
    )
    banner.classList.remove("hidden")
  }

  function hideBanner() {
    banner.classList.add("hidden")
    banner.dataset.kind = ""
  }

  function offerDraft(draft) {
    const when = new Date(draft.at).toLocaleTimeString([], {hour: "2-digit", minute: "2-digit"})
    const older = draft.version !== version
    showBanner(
      "draft",
      older
        ? `Unsaved changes from ${when}, made before this workflow was saved elsewhere.`
        : `You have unsaved changes from ${when}.`,
      [
        ["wf-draft-discard", "Discard", () => {
          clearDraft(workflowId)
          hideBanner()
        }],
        ["wf-draft-restore", "Restore", () => {
          hideBanner()
          version = draft.version
          commit(fromServer(draft.graph), {select: {}})
        }, true],
      ],
    )
  }

  function showStale(current) {
    showBanner("stale", "This workflow was saved elsewhere (another tab?) since you opened it.", [
      ["wf-stale-reload", "Load theirs", () => {
        clearDraft(workflowId)
        leaving = true
        window.location.reload()
      }],
      ["wf-stale-overwrite", "Overwrite with mine", () => {
        version = current
        hideBanner()
        save()
      }, true],
    ])
  }

  let labelTimer = null
  function setSaveLabel(text, resetAfter) {
    clearTimeout(labelTimer)
    $("#wf-save [data-label]").textContent = text
    $("#wf-save").classList.toggle("is-saved", text === "Saved")
    if (resetAfter) labelTimer = setTimeout(() => setSaveLabel("Save"), resetAfter)
  }

  // Actions (toolbar, inspector, menu, keys)

  const actions = {
    select,
    reveal(id) {
      const item = findNode(graph, id)
      select(item ? {nodes: [id]} : {edges: [id]})
      const box = item ? rect(item) : edgeBox(findEdge(graph, id))
      if (box) centerOn(box)
    },
    updateNode(id, changes, {relabel} = {}) {
      const node = findNode(graph, id)
      const next = {...changes}
      if (relabel && node.label === defaultLabel(node)) next.label = defaultLabel({...node, ...changes})
      commit(updateNode(graph, id, next))
    },
    updateEdge(id, changes) {
      commit(updateEdge(graph, id, changes))
    },
    unpin(id) {
      const edge = findEdge(graph, id)
      commit(reroute(updateEdge(graph, id, {pinned: false}), [edge.from]), {select: {edges: [id]}})
    },
    // An arrow's end onto another block (the inspector's From / To): its dot faces the
    // other end; onto its own block it becomes a loop.
    retarget(id, end, nodeId) {
      const edge = findEdge(graph, id)
      const node = findNode(graph, nodeId)
      const [other, otherSide] = end === "to" ? [edge.from, edge.from_port] : [edge.to, edge.to_port]
      const side = facingSide(rect(node), portPoint(rect(findNode(graph, other)), otherSide))
      const changes = end === "to" ? {to: nodeId, to_port: side} : {from: nodeId, from_port: side}
      const next = {...edge, ...changes}
      if (next.from === next.to) Object.assign(changes, {to_port: next.from_port, iterations: edge.iterations || 2})
      commit(updateEdge(graph, id, changes), {select: {edges: [id]}})
    },
    setStart(id) {
      commit(setStart(graph, id))
    },
    remove() {
      if (selection.nodes.size + selection.edges.size === 0) return
      commit(remove(graph, {nodes: [...selection.nodes], edges: [...selection.edges]}), {select: {}})
    },
    group() {
      if (selection.nodes.size === 0) return
      const count = graph.nodes.filter(isGroup).length + 1
      const result = group(graph, [...selection.nodes], `Group ${count}`)
      commit(result.graph, {select: {nodes: [result.group.id]}})
    },
    ungroup(id) {
      const ids = id ? [id] : selectedGroups()
      if (ids.length === 0) return
      const inside = ids.flatMap((one) => graph.nodes.filter((node) => node.group_id === one).map((node) => node.id))
      commit(ids.reduce(ungroup, graph), {select: {nodes: inside}})
    },
    duplicate() {
      if (selection.nodes.size === 0) return
      const result = duplicate(graph, subgraph(graph, [...selection.nodes]), GRID * 2)
      commit(result.graph, {select: {nodes: result.ids}})
    },
    copy() {
      if (selection.nodes.size === 0) return
      clipboard = subgraph(graph, [...selection.nodes])
      pastes = 0
    },
    paste() {
      if (!clipboard) return
      pastes++
      const result = duplicate(graph, clipboard, GRID * 2 * pastes)
      commit(result.graph, {select: {nodes: result.ids}})
    },
    undo: () => restore(history.undo()),
    redo: () => restore(history.redo()),
  }

  function defaultLabel(node) {
    if (node.kind === "agent") {
      const agent = node.employee_id && catalog.employee(node.employee_id)
      return agent ? agent.name : catalog.roleLabel(node.agent_role)
    }
    if (node.kind === "human") {
      const person = node.employee_id && catalog.employee(node.employee_id)
      return person ? person.name : "Review"
    }
    if (node.kind === "column") return catalog.columnLabel(node.column_status)
    return node.label
  }

  function edgeBox(edge) {
    const from = findNode(graph, edge.from)
    const to = findNode(graph, edge.to)
    return bounds([from, to])
  }

  // Camera

  function toWorld(clientX, clientY) {
    const box = viewport.getBoundingClientRect()
    return {x: (clientX - box.left - camera.x) / camera.zoom, y: (clientY - box.top - camera.y) / camera.zoom}
  }

  function zoomAt(factor, clientX, clientY) {
    const box = viewport.getBoundingClientRect()
    const anchorX = clientX ?? box.left + box.width / 2
    const anchorY = clientY ?? box.top + box.height / 2
    const before = toWorld(anchorX, anchorY)
    const zoom = clamp(camera.zoom * factor, ZOOM.min, ZOOM.max)
    camera = {
      zoom,
      x: anchorX - box.left - before.x * zoom,
      y: anchorY - box.top - before.y * zoom,
    }
    applyCamera()
  }

  function fit() {
    const box = viewport.getBoundingClientRect()
    const area = bounds(graph.nodes)
    if (!area) {
      camera = {x: box.width / 2 - BLOCK.width / 2, y: box.height / 3, zoom: 1}
    } else {
      const zoom = clamp(Math.min((box.width - 120) / area.width, (box.height - 160) / area.height), ZOOM.min, 1.1)
      camera = {
        zoom,
        x: (box.width - area.width * zoom) / 2 - area.x * zoom,
        y: (box.height - area.height * zoom) / 2 - area.y * zoom,
      }
    }
    applyCamera()
  }

  function centerOn(area) {
    const box = viewport.getBoundingClientRect()
    camera = {
      ...camera,
      x: box.width / 2 - (area.x + area.width / 2) * camera.zoom,
      y: box.height / 2 - (area.y + area.height / 2) * camera.zoom,
    }
    applyCamera()
  }

  // Where new blocks land when added without dragging: the middle of the view, nudged down
  // off any block already there, with room between them for an arrow and its label.
  function freeSpot(size) {
    const box = viewport.getBoundingClientRect()
    const middle = toWorld(box.left + box.width / 2, box.top + box.height / 2)
    const gap = GRID * 3
    const origin = {x: snap(middle.x - size.width / 2), y: snap(middle.y - size.height / 2)}
    const taken = (point) =>
      graph.nodes.some((node) => !isGroup(node) && Math.abs(node.x - point.x) < BLOCK.width && Math.abs(node.y - point.y) < BLOCK.height + gap)
    // Down a column of eight, then the next column to the right.
    for (let step = 0; step < 400; step++) {
      const spot = {
        x: origin.x + Math.floor(step / 8) * (BLOCK.width + gap),
        y: origin.y + (step % 8) * (BLOCK.height + gap),
      }
      if (!taken(spot)) return spot
    }
    return origin
  }

  // Adding blocks from the palette

  function blockFrom(item, spot) {
    const kind = item.dataset.kind
    const size = kind === "group" ? GROUP : BLOCK
    return {
      id: newId(kind === "group" ? "g" : "n"),
      kind,
      label: item.dataset.label,
      employee_id: item.dataset.employeeId || null,
      agent_role: item.dataset.agentRole || null,
      column_status: item.dataset.columnStatus || null,
      group_id: null,
      color: kind === "group" ? "blue" : null,
      prompt: null,
      stall_timeout_minutes: null,
      turn_timeout_minutes: null,
      merge_branch: null,
      start: false,
      x: spot.x,
      y: spot.y,
      width: kind === "group" ? size.width : null,
      height: kind === "group" ? size.height : null,
    }
  }

  function add(item, spot) {
    const node = blockFrom(item, spot)
    commit(addNode(graph, node), {select: {nodes: [node.id]}})
    requestAnimationFrame(() => renderer.element(node.id)?.focus({preventScroll: true}))
  }

  // A block dropped onto a dot: placed beyond that side and connected from there, in one
  // undoable step; the new arrow is selected for its condition.
  const BEYOND = {right: [1, 0], left: [-1, 0], bottom: [0, 1], top: [0, -1]}
  const OPPOSITE = {right: "left", left: "right", bottom: "top", top: "bottom"}

  function addConnected(item, {id, side}) {
    const source = findNode(graph, id)
    const box = rect(source)
    const size = sizeOf(item)
    const [dx, dy] = BEYOND[side]
    const spot = {
      x: snap(dx > 0 ? box.x + box.width + GRID * 7 : dx < 0 ? box.x - size.width - GRID * 7 : box.x + (box.width - size.width) / 2),
      y: snap(dy > 0 ? box.y + box.height + GRID * 5 : dy < 0 ? box.y - size.height - GRID * 5 : box.y + (box.height - size.height) / 2),
    }
    const node = blockFrom(item, clearOf(spot, size, side))
    const result = connect(addNode(graph, node), {from: id, to: node.id, fromPort: side, toPort: OPPOSITE[side]})
    commit(result.graph, {select: {edges: [result.edge.id]}})
    keepInView(rect(node))
    focusCondition()
  }

  // A spot near `spot` where a new block of `size` keeps clear of every other block (groups
  // may hold it): sideways off the arrow's line first, alternating, then further out along it.
  function clearOf(spot, size, side) {
    const margin = GRID * 2
    const blocks = graph.nodes.filter((node) => !isGroup(node)).map(rect)
    const free = (place) =>
      blocks.every(
        (other) =>
          place.x + size.width + margin <= other.x ||
          other.x + other.width + margin <= place.x ||
          place.y + size.height + margin <= other.y ||
          other.y + other.height + margin <= place.y,
      )
    const [dx, dy] = BEYOND[side]
    const across = {x: Math.abs(dy) * (size.width + margin * 2), y: Math.abs(dx) * (size.height + margin * 2)}
    const along = {x: dx * (size.width + margin * 2), y: dy * (size.height + margin * 2)}
    for (let out = 0; out < 6; out++) {
      for (const step of [0, 1, -1, 2, -2, 3, -3]) {
        const place = {
          x: snap(spot.x + along.x * out + across.x * step),
          y: snap(spot.y + along.y * out + across.y * step),
        }
        if (free(place)) return place
      }
    }
    return spot
  }

  // Pans just enough for the box to show, with a margin.
  function keepInView(area) {
    const box = viewport.getBoundingClientRect()
    const margin = 40
    const left = area.x * camera.zoom + camera.x
    const top = area.y * camera.zoom + camera.y
    const right = left + area.width * camera.zoom
    const bottom = top + area.height * camera.zoom
    const dx = right > box.width - margin ? box.width - margin - right : left < margin ? margin - left : 0
    const dy = bottom > box.height - margin ? box.height - margin - bottom : top < margin ? margin - top : 0
    if (dx || dy) {
      camera = {...camera, x: camera.x + dx, y: camera.y + dy}
      applyCamera()
    }
  }

  // Quick add: a search over the palette, opened where the canvas was double-clicked (or
  // from its menu), adding the picked block at that point.
  function openQuickAdd(clientX, clientY) {
    closeMenu()
    const box = viewport.getBoundingClientRect()
    const point = toWorld(clientX, clientY)
    const items = [...palette.querySelectorAll("[data-palette]")]
    let active = 0
    let matches = []
    const input = el("input", {
      id: "wf-quick-search",
      class: "input input-sm w-full",
      placeholder: "Add a block…",
      autocomplete: "off",
      role: "combobox",
      "aria-label": "Search blocks to add",
      "aria-controls": "wf-quick-list",
      "aria-expanded": "true",
    })
    const list = el("ul", {class: "wf-quick-list", id: "wf-quick-list", role: "listbox", "aria-label": "Blocks"})
    const pick = (item) => {
      closeQuickAdd()
      const size = sizeOf(item)
      add(item, {x: snap(point.x - size.width / 2), y: snap(point.y - size.height / 2)})
    }
    const draw = () => {
      const query = input.value.trim().toLowerCase()
      matches = items.filter((item) => !query || item.dataset.search.includes(query)).slice(0, 8)
      active = clamp(active, 0, Math.max(0, matches.length - 1))
      input.setAttribute("aria-activedescendant", matches.length ? `wf-quick-${matches[active].id}` : "")
      list.replaceChildren(
        ...(matches.length
          ? matches.map((item, index) =>
              el(
                "li",
                {
                  id: `wf-quick-${item.id}`,
                  role: "option",
                  "aria-selected": String(index === active),
                  class: ["wf-quick-item", item.className.match(/tone-\S+/)?.[0], index === active && "is-active"].filter(Boolean).join(" "),
                  onpointerdown: (event) => {
                    event.preventDefault()
                    pick(item)
                  },
                  onpointermove: () => {
                    if (active === index) return
                    active = index
                    draw()
                  },
                },
                [
                  el("span", {class: "wf-quick-dot"}),
                  el("span", {class: "min-w-0 flex-1 truncate font-medium", text: item.dataset.label}),
                  el("span", {class: "truncate text-xs text-(--orpheus-text-muted)", text: item.querySelector(".text-xs")?.textContent.trim() || ""}),
                ],
              ),
            )
          : [el("li", {class: "wf-quick-empty", text: "No block matches."})]),
      )
    }
    input.addEventListener("input", () => {
      active = 0
      draw()
    })
    input.addEventListener("keydown", (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") return
      event.stopPropagation()
      const moves = {ArrowDown: 1, ArrowUp: -1}
      if (moves[event.key] && matches.length) {
        event.preventDefault()
        active = (active + moves[event.key] + matches.length) % matches.length
        draw()
      } else if (event.key === "Enter" && matches[active]) {
        event.preventDefault()
        pick(matches[active])
      } else if (event.key === "Escape") {
        closeQuickAdd()
        viewport.focus({preventScroll: true})
      }
    })
    input.addEventListener("blur", () => setTimeout(() => quick.contains(document.activeElement) || closeQuickAdd(), 0))
    quick.replaceChildren(input, list)
    quick.style.left = `${clamp(clientX - box.left, 8, box.width - 300)}px`
    quick.style.top = `${clamp(clientY - box.top, 8, box.height - 340)}px`
    quick.classList.remove("hidden")
    draw()
    input.focus()
  }

  function closeQuickAdd() {
    if (quick.classList.contains("hidden")) return
    quick.classList.add("hidden")
    quick.replaceChildren()
  }

  function quickAddInMiddle() {
    const box = viewport.getBoundingClientRect()
    openQuickAdd(box.left + box.width / 2 - 140, box.top + box.height / 2 - 60)
  }

  const sizeOf = (item) => (item.dataset.kind === "group" ? GROUP : BLOCK)

  // Pointer gestures

  // The block (and its dot) under the pointer: the dot itself, or for a drop on the block's
  // body the dot facing `other`, the arrow's other end.
  function nodeAt(clientX, clientY, other) {
    const hit = document.elementFromPoint(clientX, clientY)
    if (!hit || !viewport.contains(hit)) return null
    const port = hit.closest("[data-port]")
    if (port) return {id: port.dataset.nodeId, side: port.dataset.port}
    const element = hit.closest("[data-node-id]")
    if (!element) return null
    const node = findNode(graph, element.dataset.nodeId)
    if (!node) return null
    const toward = other && other.id !== node.id ? other.point : toWorld(clientX, clientY)
    return {id: node.id, side: other && other.id !== node.id ? facingSide(rect(node), toward) : nearestSide(rect(node), toward)}
  }

  // The fixed end of the arrow being drawn or re-attached, which a body drop faces.
  function otherEnd(drag) {
    if (drag.type === "connect") return {id: drag.from, point: drag.origin}
    const edge = findEdge(graph, drag.edge)
    const id = drag.end === "to" ? edge.from : edge.to
    const side = drag.end === "to" ? edge.from_port : edge.to_port
    return {id, point: portPoint(rect(findNode(graph, id)), side)}
  }

  function groupAt(clientX, clientY) {
    const hit = document.elementFromPoint(clientX, clientY)
    return hit?.closest?.(".wf-group")?.dataset.nodeId || null
  }

  function onPointerDown(event) {
    if (!event.target.closest("[data-menu]")) closeMenu()
    if (!event.target.closest("[data-quick]")) closeQuickAdd()
    if (event.button === 2 || event.target.closest("input, select, textarea, [data-menu], [data-quick], #wf-empty button")) return
    pointerActive = true
    const point = toWorld(event.clientX, event.clientY)
    const client = {x: event.clientX, y: event.clientY}
    const target = event.target

    if (event.button === 1 || spaceHeld) {
      event.preventDefault()
      gesture = {type: "pan", client, camera: {...camera}, moved: false}
      return
    }

    const port = target.closest("[data-port]")
    if (port) {
      event.preventDefault()
      const node = findNode(graph, port.dataset.nodeId)
      gesture = {type: "connect", from: node.id, side: port.dataset.port, origin: portPoint(rect(node), port.dataset.port)}
      return
    }

    const handle = target.closest("[data-edge-handle]")
    if (handle) {
      event.preventDefault()
      const edge = findEdge(graph, handle.dataset.edgeId)
      gesture = {type: "reattach", edge: edge.id, end: handle.dataset.edgeHandle}
      return
    }

    const remover = target.closest("[data-edge-delete]")
    if (remover) {
      event.preventDefault()
      commit(remove(graph, {nodes: [], edges: [remover.dataset.edgeDelete]}), {select: {}})
      return
    }

    const edgeElement = target.closest("[data-edge-id]")
    if (edgeElement) {
      event.preventDefault()
      const id = edgeElement.dataset.edgeId
      event.shiftKey ? toggle("edges", id) : select({edges: [id]})
      return
    }

    const resize = target.closest("[data-resize]")
    if (resize) {
      event.preventDefault()
      const node = findNode(graph, resize.closest("[data-node-id]").dataset.nodeId)
      gesture = {type: "resize", id: node.id, start: point, origin: rect(node), base: graph}
      return
    }

    const nodeElement = target.closest("[data-node-id]")
    if (nodeElement) {
      const id = nodeElement.dataset.nodeId
      if (event.shiftKey) toggle("nodes", id)
      else if (!selection.nodes.has(id)) select({nodes: [id]})
      const moving = withContents(graph, [...selection.nodes])
      gesture = {
        type: "move",
        id,
        shift: event.shiftKey,
        start: point,
        client,
        base: graph,
        origins: Object.fromEntries(moving.map((one) => [one, {x: findNode(graph, one).x, y: findNode(graph, one).y}])),
        moved: false,
      }
      return
    }

    event.preventDefault()
    viewport.focus({preventScroll: true})
    gesture = event.shiftKey
      ? {type: "rubber", start: point, client, moved: false}
      : {type: "pan", client, camera: {...camera}, moved: false}
  }

  function onPalettePointerDown(event) {
    const item = event.target.closest("[data-palette]")
    if (!item || event.button !== 0) return
    gesture = {type: "palette", item, client: {x: event.clientX, y: event.clientY}, moved: false, ghost: null}
  }

  function onPointerMove(event) {
    if (!gesture) return
    const client = {x: event.clientX, y: event.clientY}
    const far = () => Math.hypot(client.x - gesture.client.x, client.y - gesture.client.y) > DRAG_THRESHOLD
    const point = toWorld(client.x, client.y)

    switch (gesture.type) {
      case "pan":
        if (!gesture.moved && !far()) return
        gesture.moved = true
        viewport.classList.add("is-panning")
        camera = {...camera, x: gesture.camera.x + client.x - gesture.client.x, y: gesture.camera.y + client.y - gesture.client.y}
        applyCamera()
        return

      case "move": {
        if (!gesture.moved && !far()) return
        gesture.moved = true
        const moved = align(moveNodes(gesture.base, gesture.origins, point.x - gesture.start.x, point.y - gesture.start.y), gesture)
        const home = findNode(assignGroups(moved), gesture.id)?.group_id || null
        dropTarget = home !== findNode(gesture.base, gesture.id)?.group_id ? home : null
        viewport.classList.add("is-dragging")
        preview(moved)
        return
      }

      case "resize":
        preview(resizeGroup(gesture.base, gesture.id, gesture.origin, point.x - gesture.start.x, point.y - gesture.start.y))
        return

      case "connect":
      case "reattach": {
        const target = nodeAt(client.x, client.y, otherEnd(gesture))
        dropTarget = target?.id || null
        previewPath = previewCurve(gesture, point, target)
        refresh({panel: false})
        return
      }

      case "rubber": {
        if (!gesture.moved && !far()) return
        gesture.moved = true
        const box = viewport.getBoundingClientRect()
        const left = Math.min(client.x, gesture.client.x) - box.left
        const top = Math.min(client.y, gesture.client.y) - box.top
        Object.assign(rubber.style, {
          left: `${left}px`,
          top: `${top}px`,
          width: `${Math.abs(client.x - gesture.client.x)}px`,
          height: `${Math.abs(client.y - gesture.client.y)}px`,
        })
        rubber.classList.remove("hidden")
        const area = {
          x: Math.min(point.x, gesture.start.x),
          y: Math.min(point.y, gesture.start.y),
          right: Math.max(point.x, gesture.start.x),
          bottom: Math.max(point.y, gesture.start.y),
        }
        const within = graph.nodes.filter((node) => {
          const box = rect(node)
          return box.x >= area.x && box.y >= area.y && box.x + box.width <= area.right && box.y + box.height <= area.bottom
        })
        selection = {nodes: new Set(within.map((node) => node.id)), edges: new Set()}
        refresh()
        return
      }

      case "palette": {
        if (!gesture.moved && !far()) return
        gesture.moved = true
        if (!gesture.ghost) {
          gesture.ghost = gesture.item.cloneNode(true)
          gesture.ghost.removeAttribute("id")
          gesture.ghost.classList.add("wf-ghost")
          document.body.append(gesture.ghost)
        }
        gesture.ghost.style.transform = `translate(${client.x - 24}px, ${client.y - 20}px)`
        const over = document.elementFromPoint(client.x, client.y)
        const onCanvas = over && viewport.contains(over)
        viewport.classList.toggle("is-drop", Boolean(onCanvas))
        const dot = onCanvas ? over.closest("[data-port]") : null
        const target = dot ? dot.dataset.nodeId : onCanvas ? groupAt(client.x, client.y) : null
        if (target !== dropTarget) {
          dropTarget = target
          refresh({panel: false})
        }
        return
      }
    }
  }

  // Snap guides: the dragged block's edges and centre lining up with a block or group near
  // it (within a few screen pixels) snap onto it, and a line shows each alignment.
  const ALIGN_PX = 6
  const NEAR = 900

  function align(moved, drag) {
    const ids = Object.keys(drag.origins)
    const moving = new Set(ids)
    const anchor = findNode(moved, drag.id)
    const box = rect(anchor)
    const others = moved.nodes
      .filter((node) => !moving.has(node.id) && !encloses(rect(node), box))
      .map(rect)
      .filter((other) => Math.abs(other.x - box.x) < NEAR && Math.abs(other.y - box.y) < NEAR)
    const lines = (one) => ({
      x: [one.x, one.x + one.width / 2, one.x + one.width],
      y: [one.y, one.y + one.height / 2, one.y + one.height],
    })
    const own = lines(box)
    const snapOf = (axis) => {
      let best = null
      for (const other of others) {
        for (const value of lines(other)[axis]) {
          for (const mine of own[axis]) {
            const delta = value - mine
            if (Math.abs(delta) <= ALIGN_PX / camera.zoom && (!best || Math.abs(delta) < Math.abs(best))) best = delta
          }
        }
      }
      return best || 0
    }
    const aligned = nudgeNodes(moved, ids, snapOf("x"), snapOf("y"))
    drawGuides(guidesFor(rect(findNode(aligned, drag.id)), others, lines))
    return aligned
  }

  const encloses = (outer, inner) =>
    inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.width <= outer.x + outer.width && inner.y + inner.height <= outer.y + outer.height

  // One line per value the box shares with others, spanning all of them.
  function guidesFor(box, others, lines) {
    const own = lines(box)
    const found = []
    for (const axis of ["x", "y"]) {
      for (const value of own[axis]) {
        const sharing = others.filter((other) => lines(other)[axis].some((one) => Math.abs(one - value) < 0.5))
        if (!sharing.length) continue
        const across = axis === "x" ? "y" : "x"
        const size = axis === "x" ? "height" : "width"
        const all = [box, ...sharing]
        const from = Math.min(...all.map((one) => one[across])) - 12
        const to = Math.max(...all.map((one) => one[across] + one[size])) + 12
        found.push(axis === "x" ? {x1: value, y1: from, x2: value, y2: to} : {x1: from, y1: value, x2: to, y2: value})
      }
    }
    return found
  }

  function drawGuides(lines) {
    guides.replaceChildren(...lines.map((line) => svg("line", {class: "wf-guide", ...line})))
  }

  function previewCurve(drag, point, target) {
    const node = target && findNode(graph, target.id)
    if (drag.type === "connect") {
      if (node && node.id === drag.from) return {d: shapeOf({from: node.id, to: node.id, from_port: drag.side}, node, node).d}
      const end = node ? portPoint(rect(node), target.side) : point
      return curve(drag.origin, drag.side, end, node ? target.side : undefined)
    }
    const edge = findEdge(graph, drag.edge)
    const fixedNode = findNode(graph, drag.end === "to" ? edge.from : edge.to)
    const fixedSide = drag.end === "to" ? edge.from_port : edge.to_port
    const fixed = portPoint(rect(fixedNode), fixedSide)
    const free = node ? portPoint(rect(node), target.side) : point
    return drag.end === "to"
      ? curve(fixed, fixedSide, free, node ? target.side : undefined)
      : curve(free, node ? target.side : "right", fixed, fixedSide)
  }

  function onPointerUp(event) {
    const done = gesture
    gesture = null
    pointerActive = false
    viewport.classList.remove("is-panning", "is-dragging", "is-drop")
    if (!done) return
    const client = {x: event.clientX, y: event.clientY}

    switch (done.type) {
      case "pan":
        if (!done.moved) select()
        break

      case "move":
        dropTarget = null
        drawGuides([])
        if (done.moved) commit(fitGroups(assignGroups(graph)))
        else if (!done.shift && selection.nodes.size > 1) select({nodes: [done.id]})
        else refresh({panel: false})
        break

      case "resize":
        commit(assignGroups(graph))
        break

      case "connect": {
        const target = nodeAt(client.x, client.y, otherEnd(done))
        previewPath = null
        dropTarget = null
        if (target) {
          const result = connect(graph, {from: done.from, to: target.id, fromPort: done.side, toPort: target.side})
          commit(result.graph, {select: {edges: [result.edge.id]}})
          focusCondition()
        } else refresh({panel: false})
        break
      }

      case "reattach": {
        const target = nodeAt(client.x, client.y, otherEnd(done))
        previewPath = null
        dropTarget = null
        if (target) {
          const edge = findEdge(graph, done.edge)
          // Dropped on a dot by hand: moving its blocks keeps it there.
          const changes =
            done.end === "to"
              ? {to: target.id, to_port: target.side, pinned: true}
              : {from: target.id, from_port: target.side, pinned: true}
          const next = {...edge, ...changes}
          if (next.from === next.to) Object.assign(changes, {to_port: next.from_port, iterations: edge.iterations || 2})
          commit(updateEdge(graph, edge.id, changes), {select: {edges: [edge.id]}})
        } else refresh({panel: false})
        break
      }

      case "rubber":
        rubber.classList.add("hidden")
        if (!done.moved) select()
        break

      case "palette": {
        done.ghost?.remove()
        dropTarget = null
        if (!done.moved) break
        suppressClick = true
        setTimeout(() => (suppressClick = false), 0)
        const over = document.elementFromPoint(client.x, client.y)
        const dot = over && viewport.contains(over) && over.closest("[data-port]")
        if (dot) addConnected(done.item, {id: dot.dataset.nodeId, side: dot.dataset.port})
        else if (over && viewport.contains(over)) {
          const size = sizeOf(done.item)
          const point = toWorld(client.x, client.y)
          add(done.item, {x: snap(point.x - size.width / 2), y: snap(point.y - size.height / 2)})
        } else refresh({panel: false})
        break
      }
    }
  }

  function cancelGesture() {
    if (!gesture) return false
    if (gesture.base) graph = gesture.base
    gesture.ghost?.remove()
    gesture = null
    previewPath = null
    dropTarget = null
    rubber.classList.add("hidden")
    drawGuides([])
    viewport.classList.remove("is-panning", "is-dragging", "is-drop")
    refresh()
    return true
  }

  function focusCondition() {
    requestAnimationFrame(() => requestAnimationFrame(() => document.getElementById("wf-inspector-condition")?.focus()))
  }

  // Scrolling (a wheel, two fingers on a trackpad) pans; ⌘ / ctrl + wheel and a pinch,
  // which browsers send as a wheel with ctrlKey, zoom around the pointer.
  function onWheel(event) {
    event.preventDefault()
    if (event.ctrlKey || event.metaKey) {
      zoomAt(Math.exp(-clamp(event.deltaY, -50, 50) * 0.01), event.clientX, event.clientY)
      return
    }
    const unit = event.deltaMode === WheelEvent.DOM_DELTA_LINE ? 16 : event.deltaMode === WheelEvent.DOM_DELTA_PAGE ? viewport.clientHeight : 1
    const [dx, dy] = event.shiftKey && !event.deltaX ? [event.deltaY, 0] : [event.deltaX, event.deltaY]
    camera = {...camera, x: camera.x - dx * unit, y: camera.y - dy * unit}
    applyCamera()
  }

  // Renaming in place

  function rename(id) {
    const node = findNode(graph, id)
    const element = renderer.element(id)
    const label = element?.querySelector("[data-label]")
    if (!node || !label) return
    let finished = false
    const input = el("input", {id: "wf-rename", class: "wf-rename", value: node.label, maxlength: "100", "aria-label": "Name"})
    const finish = (keep) => {
      if (finished) return
      finished = true
      const value = input.value.trim()
      element.dataset.signature = ""
      if (keep && value && value !== node.label) commit(updateNode(graph, id, {label: value}))
      else refresh()
      requestAnimationFrame(() => renderer.element(id)?.focus({preventScroll: true}))
    }
    input.addEventListener("keydown", (event) => {
      // ⌘S still reaches the editor, which saves the name as typed (the blur keeps it).
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") return
      event.stopPropagation()
      if (event.key === "Enter") finish(true)
      if (event.key === "Escape") finish(false)
    })
    input.addEventListener("blur", () => finish(true))
    input.addEventListener("pointerdown", (event) => event.stopPropagation())
    label.replaceWith(input)
    input.focus()
    input.select()
  }

  function onDoubleClick(event) {
    if (event.target.closest("[data-quick], [data-menu], #wf-empty button, .wf-zoom, #wf-banner")) return
    const edge = event.target.closest("[data-edge-id]")
    if (edge) {
      select({edges: [edge.dataset.edgeId]})
      focusCondition()
      return
    }
    const node = event.target.closest("[data-node-id]")
    if (node && !event.target.closest("[data-port], [data-resize]")) {
      // A group's body: add a block into it, there.
      if (isGroup(findNode(graph, node.dataset.nodeId)) && !event.target.closest("[data-group-header]"))
        return openQuickAdd(event.clientX, event.clientY)
      rename(node.dataset.nodeId)
      return
    }
    if (!node) openQuickAdd(event.clientX, event.clientY)
  }

  // Context menu

  function openMenu(event) {
    event.preventDefault()
    const edge = event.target.closest("[data-edge-id]")
    const node = event.target.closest("[data-node-id]")
    if (edge && !selection.edges.has(edge.dataset.edgeId)) select({edges: [edge.dataset.edgeId]})
    if (node && !selection.nodes.has(node.dataset.nodeId)) select({nodes: [node.dataset.nodeId]})
    if (!edge && !node) select()

    const id = node?.dataset.nodeId
    const item = (key, text, shortcut, run, {danger} = {}) =>
      el(
        "button",
        {
          type: "button",
          role: "menuitem",
          id: `wf-menu-${key}`,
          class: ["wf-menu-item", danger && "is-danger"].filter(Boolean).join(" "),
          onclick: () => {
            closeMenu()
            run()
          },
        },
        [el("span", {text}), shortcut ? el("kbd", {text: shortcut}) : null],
      )

    const entries = node
      ? [
          item("rename", "Rename", "↵", () => rename(id)),
          item("start", "Set as start", null, () => actions.setStart(id)),
          item("duplicate", "Duplicate", "⌘D", actions.duplicate),
          item("group", "Group", "⌘G", actions.group),
          isGroup(findNode(graph, id)) ? item("ungroup", "Ungroup", "⇧⌘G", () => actions.ungroup(id)) : null,
          item("delete", "Delete", "⌫", actions.remove, {danger: true}),
        ]
      : edge
        ? [
            item("condition", "Edit condition", "↵", focusCondition),
            item("delete", "Delete arrow", "⌫", actions.remove, {danger: true}),
          ]
        : [
            item("add", "Add a block here…", "dbl-click", () => openQuickAdd(event.clientX, event.clientY)),
            clipboard ? item("paste", "Paste", "⌘V", actions.paste) : null,
            item("select-all", "Select all", "⌘A", () => select({nodes: graph.nodes.map((node) => node.id)})),
            item("fit", "Fit to view", "⇧1", fit),
          ]

    const box = viewport.getBoundingClientRect()
    menu.replaceChildren(...entries.filter(Boolean))
    menu.style.left = `${Math.min(event.clientX - box.left, box.width - 200)}px`
    menu.style.top = `${Math.min(event.clientY - box.top, box.height - 240)}px`
    menu.classList.remove("hidden")
    menu.querySelector("button")?.focus()
  }

  function closeMenu() {
    menu.classList.add("hidden")
  }

  // Keys

  function onKeyDown(event) {
    const mod = event.metaKey || event.ctrlKey
    const key = event.key.toLowerCase()

    if (mod && key === "s") {
      event.preventDefault()
      saveTyped()
      return
    }
    if (typing(event.target)) return
    if (event.target !== document.body && !root.contains(event.target)) return

    if (key === " " && !event.repeat && !event.target.closest("button")) {
      spaceHeld = true
      event.preventDefault()
      chrome()
      return
    }
    if (key === "escape") {
      if (!menu.classList.contains("hidden")) closeMenu()
      else if (!cancelGesture()) select()
      return
    }

    const run = (action) => {
      event.preventDefault()
      action()
    }

    if (mod && key === "z") return run(event.shiftKey ? actions.redo : actions.undo)
    if (mod && key === "y") return run(actions.redo)
    if (mod && key === "d") return run(actions.duplicate)
    if (mod && key === "c") return run(actions.copy)
    if (mod && key === "v") return run(actions.paste)
    if (mod && key === "g") return run(event.shiftKey ? () => actions.ungroup() : actions.group)
    if (mod && key === "a") return run(() => select({nodes: graph.nodes.map((node) => node.id)}))
    if (mod) return

    if (key === "delete" || key === "backspace") return run(actions.remove)
    if (event.code === "Digit1" && event.shiftKey) return run(fit)
    if (key === "+" || key === "=") return run(() => zoomAt(1.2))
    if (key === "-") return run(() => zoomAt(1 / 1.2))
    if (key === "0") return run(() => zoomAt(1 / camera.zoom))

    const node = event.target.closest?.("[data-node-id]")
    if (key === "enter" && node) return run(() => rename(node.dataset.nodeId))
    if (key === "enter" && selection.edges.size === 1 && selection.nodes.size === 0) return run(focusCondition)

    const arrows = {arrowleft: [-1, 0], arrowright: [1, 0], arrowup: [0, -1], arrowdown: [0, 1]}
    if (arrows[key] && selection.nodes.size) {
      const step = GRID * (event.shiftKey ? 5 : 1)
      const ids = withContents(graph, [...selection.nodes])
      const origins = Object.fromEntries(ids.map((id) => [id, findNode(graph, id)]))
      return run(() => commit(fitGroups(assignGroups(moveNodes(graph, origins, arrows[key][0] * step, arrows[key][1] * step)))))
    }
  }

  // Inspector fields commit on change, which only fires as they lose focus: ⌘S in one
  // commits it first, then saves, and gives the focus back.
  function saveTyped() {
    const field = document.activeElement
    const editing = field && root.contains(field) && typing(field) && field.id !== "wf-palette-search"
    if (editing) field.blur()
    save()
    if (editing && field.id) document.getElementById(field.id)?.focus()
  }

  function onKeyUp(event) {
    if (event.key === " ") {
      spaceHeld = false
      chrome()
    }
  }

  // Keyboard users select by focusing; a click already selected what it wanted.
  function onFocusIn(event) {
    if (pointerActive) return
    const label = event.target.closest(".wf-edge-label")
    if (label && !selection.edges.has(label.dataset.edgeId)) return select({edges: [label.dataset.edgeId]})
    const node = event.target.closest("[data-node-id]")
    if (node && (event.target.matches(".wf-node") || event.target.matches("[data-group-header]"))) {
      if (!selection.nodes.has(node.dataset.nodeId)) select({nodes: [node.dataset.nodeId]})
    }
  }

  function onPaletteClick(event) {
    const item = event.target.closest("[data-palette]")
    if (!item || suppressClick) return
    add(item, freeSpot(sizeOf(item)))
  }

  // Sections the person closed stay closed (per browser); a search opens every section
  // with a match and counts what matches, and clearing it puts the sections back.
  const CLOSED_KEY = "wf-palette-closed"
  const sections = [...palette.querySelectorAll(".wf-palette-section")]
  let searching = false

  function closedSections() {
    try {
      return new Set(JSON.parse(localStorage.getItem(CLOSED_KEY) || "[]"))
    } catch {
      return new Set()
    }
  }

  function onSectionToggle(event) {
    const section = event.target
    if (searching || !section.matches?.(".wf-palette-section")) return
    const closed = closedSections()
    section.open ? closed.delete(section.dataset.section) : closed.add(section.dataset.section)
    try {
      localStorage.setItem(CLOSED_KEY, JSON.stringify([...closed]))
    } catch {
      // Not remembered: sections open again next time.
    }
  }

  function onSearch(event) {
    const query = event.target.value.trim().toLowerCase()
    const closed = closedSections()
    searching = true
    let any = false
    for (const section of sections) {
      const items = [...section.querySelectorAll("[data-palette]")]
      let visible = 0
      for (const item of items) {
        const match = !query || item.dataset.search.includes(query)
        item.classList.toggle("hidden", !match)
        if (match) visible++
      }
      section.classList.toggle("hidden", visible === 0)
      section.open = query ? visible > 0 : !closed.has(section.dataset.section)
      section.querySelector("[data-count]").textContent = query ? `${visible}/${items.length}` : String(items.length)
      any = any || visible > 0
    }
    palette.querySelector(".wf-palette-empty").classList.toggle("hidden", any)
    // toggle events fire after this task, so the flag drops once they ran.
    setTimeout(() => (searching = false), 0)
  }

  function onBeforeUnload(event) {
    if (!dirty() || leaving) return
    event.preventDefault()
    event.returnValue = ""
  }

  // Whether the person may leave now: asks once with unsaved changes. A yes holds until the
  // next edit, so the unload that may follow (a link without LiveView) asks no more.
  function mayLeave() {
    if (!dirty() || leaving) return true
    leaving = window.confirm(LEAVE_WARNING)
    return leaving
  }

  // LiveView navigation (its links, back / forward between its pages) fires no
  // beforeunload; it asks through this cancelable event, and puts history back on a "stay".
  function onBeforeNavigate(event) {
    if (!mayLeave()) event.preventDefault()
  }

  // A link that only runs a LiveView event, which may navigate from the server (a
  // notification in the bell's panel), asks first as well.
  function onEventLinkClick(event) {
    if (!event.target.closest?.('a[href="#"][phx-click]') || mayLeave()) return
    event.preventDefault()
    event.stopImmediatePropagation()
  }

  // Other ways out (a notification toast opening its task) ask through this event.
  function onLeaveRequest(event) {
    if (!mayLeave()) event.preventDefault()
  }

  // Wiring

  const tools = {
    "#wf-save": save,
    "#wf-undo": actions.undo,
    "#wf-redo": actions.redo,
    "#wf-group": actions.group,
    "#wf-ungroup": () => actions.ungroup(),
    "#wf-duplicate": actions.duplicate,
    "#wf-delete": actions.remove,
    "#wf-zoom-in": () => zoomAt(1.2),
    "#wf-zoom-out": () => zoomAt(1 / 1.2),
    "#wf-zoom-reset": () => zoomAt(1 / camera.zoom),
    "#wf-fit": fit,
    "#wf-problem-count": () => select(),
    "#wf-empty-planner": () => $("#palette-role-planner").click(),
    "#wf-empty-search": quickAddInMiddle,
  }
  for (const [selector, run] of Object.entries(tools)) $(selector).addEventListener("click", run)

  const listeners = [
    [viewport, "pointerdown", onPointerDown],
    [viewport, "dblclick", onDoubleClick],
    [viewport, "contextmenu", openMenu],
    [viewport, "wheel", onWheel, {passive: false}],
    [viewport, "focusin", onFocusIn],
    [palette, "pointerdown", onPalettePointerDown],
    [palette, "click", onPaletteClick],
    [$("#wf-palette-search"), "input", onSearch],
    [palette, "toggle", onSectionToggle, true],
    [window, "pointermove", onPointerMove],
    [window, "pointerup", onPointerUp],
    [window, "pointercancel", cancelGesture],
    [window, "keydown", onKeyDown],
    [window, "keyup", onKeyUp],
    [window, "beforeunload", onBeforeUnload],
    [window, "click", onEventLinkClick, true],
    [window, "phx:before-navigate", onBeforeNavigate],
    [window, "app:leave", onLeaveRequest],
  ]
  for (const [target, type, handler, options] of listeners) target.addEventListener(type, handler, options)

  fit()
  refresh()

  const closed = closedSections()
  for (const section of sections) section.open = !closed.has(section.dataset.section)

  const draft = readDraft(workflowId)
  if (draft && fingerprint(fromServer(draft.graph)) !== saved) offerDraft(draft)
  else clearDraft(workflowId)

  return {
    destroy() {
      clearTimeout(validation.timer)
      cancelAnimationFrame(frame)
      for (const [target, type, handler, options] of listeners) target.removeEventListener(type, handler, options)
    },
  }
}
