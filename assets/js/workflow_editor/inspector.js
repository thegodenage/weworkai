// The right-hand panel: every property of the selected block, group or arrow, its problems,
// and with nothing selected the workflow's problems and the shortcuts.
import {el, icon} from "./dom.js"
import {DECISION_SUGGESTIONS} from "./catalog.js"
import {findEdge, findNode, isGroup, startId, descendants} from "./model.js"

export function renderInspector(container, view, actions) {
  const active = document.activeElement && container.contains(document.activeElement) ? document.activeElement : null
  const focused = active?.id || null
  // A field commits on change (as it loses focus): what is typed in it so far isn't in the
  // graph yet, so a redraw meanwhile (a validation reply) must keep it.
  const typed = active?.matches("input:not([type=checkbox]), textarea")
    ? {value: active.value, start: active.selectionStart, end: active.selectionEnd}
    : null
  const {nodes, edges} = view.selection
  let body

  if (nodes.size === 1 && edges.size === 0) body = nodePanel(findNode(view.graph, [...nodes][0]), view, actions)
  else if (edges.size === 1 && nodes.size === 0) body = edgePanel(findEdge(view.graph, [...edges][0]), view, actions)
  else if (nodes.size + edges.size > 1) body = manyPanel(view, actions)
  else body = overviewPanel(view, actions)

  container.replaceChildren(body)
  const again = focused && document.getElementById(focused)
  if (!again) return
  if (typed && again.matches("input, textarea")) {
    again.value = typed.value
    if (typed.start !== null) again.setSelectionRange(typed.start, typed.end)
  }
  again.focus()
}

function panel(title, subtitle, children) {
  return el("div", {class: "wf-panel", id: "wf-inspector-panel"}, [
    el("div", {class: "wf-panel-head"}, [
      el("h2", {class: "text-sm font-semibold", text: title}),
      subtitle ? el("p", {class: "text-xs text-(--orpheus-text-muted)", text: subtitle}) : null,
    ]),
    ...children,
  ])
}

function field(label, control, hint) {
  return el("label", {class: "wf-field"}, [
    el("span", {class: "wf-field-label", text: label}),
    control,
    hint ? el("span", {class: "wf-field-hint", text: hint}) : null,
  ])
}

function problemsList(messages) {
  if (messages.length === 0) return null
  return el("div", {class: "wf-problems", role: "alert", id: "wf-inspector-problems"}, [
    ...messages.map((message) => el("p", {class: "wf-problems-item"}, [icon("hero-exclamation-circle-micro", "size-4"), message])),
  ])
}

function labelInput(node, actions) {
  return el("input", {
    id: "wf-inspector-label",
    class: "input input-sm w-full",
    value: node.label,
    maxlength: "100",
    onchange: (event) => actions.updateNode(node.id, {label: event.target.value.trim() || node.label}),
    onkeydown: (event) => event.key === "Enter" && event.target.blur(),
  })
}

function startToggle(node, view, actions) {
  const isStart = startId(view.graph) === node.id
  return el("label", {class: "wf-toggle"}, [
    el("input", {
      id: "wf-inspector-start",
      type: "checkbox",
      class: "toggle toggle-sm toggle-success",
      checked: isStart,
      disabled: isStart,
      onchange: () => actions.setStart(node.id),
    }),
    el("span", {class: "text-sm"}, [
      el("span", {class: "font-medium", text: "Start block"}),
      el("span", {
        class: "block text-xs text-(--orpheus-text-muted)",
        text: isStart ? "Tasks start here." : "Make tasks start here.",
      }),
    ]),
  ])
}

function option(value, label, selected) {
  return el("option", {value, text: label, selected})
}

function whoSelect(node, view, actions) {
  const {catalog} = view
  if (node.kind === "agent") {
    const current = node.employee_id ? `employee:${node.employee_id}` : node.agent_role ? `role:${node.agent_role}` : ""
    const removed = current === "" || (node.employee_id && !catalog.employee(node.employee_id))
    return field(
      "Runs",
      el(
        "select",
        {
          id: "wf-inspector-who",
          class: "select select-sm w-full",
          onchange: (event) => {
            const [type, value] = event.target.value.split(":")
            const fields = type === "role" ? {agent_role: value, employee_id: null} : {employee_id: value, agent_role: null}
            const role = type === "role" ? value : catalog.employee(value)?.role
            // Only merger blocks merge into a branch: another role drops it.
            actions.updateNode(node.id, role === "merger" ? fields : {...fields, merge_branch: null}, {relabel: true})
          },
        },
        [
          removed ? option("", "— its agent was removed —", true) : null,
          el(
            "optgroup",
            {label: "Any agent in a role"},
            catalog.roles.map((role) => option(`role:${role.value}`, `Any ${role.label.toLowerCase()}`, current === `role:${role.value}`)),
          ),
          catalog.agents.length
            ? el(
                "optgroup",
                {label: "A specific agent"},
                catalog.agents.map((agent) =>
                  option(`employee:${agent.id}`, `${agent.name} · ${catalog.roleLabel(agent.role)}`, current === `employee:${agent.id}`),
                ),
              )
            : null,
        ],
      ),
      "A role runs the first agent in it that can run (for a coder, the one picked when the plan was approved).",
    )
  }
  if (node.kind === "human") {
    return field(
      "Decides",
      el(
        "select",
        {
          id: "wf-inspector-who",
          class: "select select-sm w-full",
          onchange: (event) => actions.updateNode(node.id, {employee_id: event.target.value || null}, {relabel: true}),
        },
        [
          option("", "Any human", !node.employee_id),
          ...catalog.humans.map((human) => option(human.id, human.name, node.employee_id === human.id)),
        ],
      ),
      "The task waits here; its page shows one button per arrow out.",
    )
  }
  if (node.kind === "column") {
    return field(
      "Column",
      el(
        "select",
        {
          id: "wf-inspector-column",
          class: "select select-sm w-full",
          onchange: (event) => actions.updateNode(node.id, {column_status: event.target.value}, {relabel: true}),
        },
        catalog.columns.map((column) => option(column.value, column.label, node.column_status === column.value)),
      ),
      "Done and Canceled end the workflow; other columns pass the task on.",
    )
  }
  if (node.kind === "triage") {
    return el("p", {
      id: "wf-inspector-triage",
      class: "wf-note",
      text: "Runs nothing: it ends with the worst severity among the open review findings (high, medium, low) or clean, and takes that arrow; an Always arrow takes the rest. Put it after a reviewer.",
    })
  }
  return null
}

const PROMPT_LIMIT = 20000

// Grows with what it holds, up to the CSS max-height (where it scrolls).
function fitHeight(area) {
  area.style.height = "auto"
  area.style.height = `${area.scrollHeight + 2}px`
}

function promptField(node, actions) {
  const area = el("textarea", {
    id: "wf-inspector-prompt",
    class: "textarea textarea-sm wf-prompt w-full",
    rows: "3",
    maxlength: String(PROMPT_LIMIT),
    placeholder: "Extra instructions for this agent in this workflow only, e.g. “Focus on security; ignore styling nits.”",
    onchange: (event) => actions.updateNode(node.id, {prompt: event.target.value.trim() || null}),
    oninput: (event) => fitHeight(event.target),
  })
  area.value = node.prompt || ""
  requestAnimationFrame(() => area.isConnected && fitHeight(area))
  return field(
    "Instructions for this block",
    area,
    "Added to the agent's prompt each time this block runs, after its role's instructions. Only in this workflow.",
  )
}

function mergeBranchField(node, actions) {
  const input = el("input", {
    id: "wf-inspector-merge-branch",
    class: "input input-sm w-full font-mono",
    maxlength: "255",
    spellcheck: "false",
    placeholder: "the checked-out branch",
    value: node.merge_branch || "",
    onchange: (event) => actions.updateNode(node.id, {merge_branch: event.target.value.trim() || null}),
  })
  return field(
    "Merge into",
    input,
    "The branch this block merges the task's branch into, without asking anyone. Blank: the branch checked out in the task's repository.",
  )
}

// Weworkai.Scheduling.Job's defaults, which a block without its own timeouts keeps.
const DEFAULT_TIMEOUTS = {stall_timeout_minutes: 15, turn_timeout_minutes: 120}

function minutesInput(node, key, actions) {
  return el("input", {
    id: `wf-inspector-${key.replaceAll("_", "-")}`,
    class: "input input-sm w-full",
    type: "number",
    min: "1",
    max: "1440",
    step: "1",
    inputmode: "numeric",
    placeholder: String(DEFAULT_TIMEOUTS[key]),
    value: node[key] ?? "",
    onchange: (event) => actions.updateNode(node.id, {[key]: event.target.value === "" ? null : Number(event.target.value)}),
  })
}

function timeoutsField(node, actions) {
  return el("div", {class: "wf-field", id: "wf-inspector-timeouts"}, [
    el("span", {class: "wf-field-label", text: "Timeouts (minutes)"}),
    el("div", {class: "grid grid-cols-2 gap-2"}, [
      el("label", {class: "wf-field"}, [el("span", {class: "wf-field-hint", text: "Silent for"}), minutesInput(node, "stall_timeout_minutes", actions)]),
      el("label", {class: "wf-field"}, [el("span", {class: "wf-field-hint", text: "Running for"}), minutesInput(node, "turn_timeout_minutes", actions)]),
    ]),
    el("span", {
      class: "wf-field-hint",
      text: "A run that writes nothing, or runs, this long is stopped and retried; after 3 attempts a human takes over. Blank keeps the default.",
    }),
  ])
}

function colorPicker(node, view, actions) {
  return field(
    "Colour",
    el(
      "div",
      {class: "flex gap-1.5", role: "radiogroup", "aria-label": "Group colour"},
      view.catalog.colors.map((color) =>
        el("button", {
          type: "button",
          id: `wf-inspector-color-${color}`,
          class: `wf-swatch wf-color-${color}`,
          role: "radio",
          "aria-checked": String((node.color || "blue") === color),
          "aria-label": color,
          title: color,
          onclick: () => actions.updateNode(node.id, {color}),
        }),
      ),
    ),
  )
}

function arrowsOut(node, view, actions) {
  const out = view.graph.edges.filter((edge) => edge.from === node.id)
  return el("div", {class: "wf-field"}, [
    el("span", {class: "wf-field-label", text: node.kind === "human" ? "Decisions (arrows out)" : "Arrows out"}),
    out.length === 0
      ? el("p", {class: "text-xs text-(--orpheus-text-muted)", text: "None yet: drag from one of its dots to another block."})
      : el(
          "ul",
          {class: "wf-arrow-list"},
          out.map((edge) => {
            const target = findNode(view.graph, edge.to)
            const errors = view.problems.get(edge.id) || []
            return el("li", {}, [
              el(
                "button",
                {
                  type: "button",
                  class: ["wf-arrow-item", errors.length && "has-error"].filter(Boolean).join(" "),
                  onclick: () => actions.select({edges: [edge.id]}),
                },
                [
                  el("span", {class: "wf-arrow-condition", text: edge.condition || (node.kind === "human" ? "unnamed" : "always")}),
                  icon("hero-arrow-long-right-micro", "size-3.5 text-(--orpheus-text-muted)"),
                  el("span", {class: "truncate", text: edge.to === edge.from ? `itself ×${edge.iterations || "?"}` : target?.label}),
                ],
              ),
            ])
          }),
        ),
  ])
}

function nodePanel(node, view, actions) {
  const {catalog} = view
  const info = catalog.describe(node)
  const messages = view.problems.get(node.id) || []
  const count = isGroup(node) ? descendants(view.graph, node.id).length : 0

  return panel(isGroup(node) ? "Group" : `${catalog.kindLabel(node)} block`, info.subtitle, [
    problemsList(messages),
    field("Name", labelInput(node, actions)),
    whoSelect(node, view, actions),
    catalog.roleOf(node) === "merger" ? mergeBranchField(node, actions) : null,
    node.kind === "agent" ? promptField(node, actions) : null,
    node.kind === "agent" ? timeoutsField(node, actions) : null,
    isGroup(node) ? colorPicker(node, view, actions) : null,
    isGroup(node)
      ? el("p", {
          class: "wf-note",
          text: `${count} ${count === 1 ? "block" : "blocks"} inside. Entering the group starts the one no arrow inside points to; a block with no arrows out leaves through the group's own arrows.`,
        })
      : null,
    startToggle(node, view, actions),
    arrowsOut(node, view, actions),
    el("div", {class: "wf-panel-actions"}, [
      isGroup(node)
        ? el("button", {type: "button", id: "wf-inspector-ungroup", class: "btn btn-ghost btn-sm", onclick: () => actions.ungroup(node.id)}, [
            icon("hero-squares-2x2-micro"),
            "Ungroup",
          ])
        : el("button", {type: "button", id: "wf-inspector-duplicate", class: "btn btn-ghost btn-sm", onclick: actions.duplicate}, [
            icon("hero-document-duplicate-micro"),
            "Duplicate",
          ]),
      el("button", {type: "button", id: "wf-inspector-delete", class: "btn btn-ghost btn-sm text-error hover:bg-error/10", onclick: actions.remove}, [
        icon("hero-trash-micro"),
        isGroup(node) ? "Delete group" : "Delete",
      ]),
    ]),
  ])
}

function conditionControl(edge, from, view, actions) {
  const outcomes = view.catalog.outcomes(from)

  if (outcomes && outcomes.length === 0) {
    return el("p", {class: "wf-note", text: "Arrows out of a column take no condition: the task simply goes on."})
  }

  if (outcomes) {
    return field(
      "When",
      el(
        "select",
        {
          id: "wf-inspector-condition",
          class: "select select-sm w-full",
          onchange: (event) => actions.updateEdge(edge.id, {condition: event.target.value || null}),
        },
        [
          option("", "Always (any other outcome)", !edge.condition),
          ...outcomes.map((outcome) => option(outcome, outcome, edge.condition === outcome)),
          edge.condition && !outcomes.includes(edge.condition) ? option(edge.condition, `${edge.condition} (not an outcome)`, true) : null,
        ],
      ),
      `${from.label} ends with ${outcomes.join(" or ")}.`,
    )
  }

  const suggestions = from.kind === "human" ? DECISION_SUGGESTIONS : view.catalog.allOutcomes
  return field(
    from.kind === "human" ? "Decision" : "When",
    el("div", {}, [
      el("input", {
        id: "wf-inspector-condition",
        class: "input input-sm w-full",
        value: edge.condition || "",
        list: "wf-condition-suggestions",
        maxlength: "100",
        placeholder: from.kind === "human" ? "e.g. accepted" : "Always",
        onchange: (event) => actions.updateEdge(edge.id, {condition: event.target.value.trim() || null}),
        onkeydown: (event) => event.key === "Enter" && event.target.blur(),
      }),
      el("datalist", {id: "wf-condition-suggestions"}, suggestions.map((value) => el("option", {value}))),
    ]),
    from.kind === "human"
      ? "The button's label on the task page."
      : "An outcome of the group's blocks; empty takes any.",
  )
}

function edgePanel(edge, view, actions) {
  const from = findNode(view.graph, edge.from)
  const to = findNode(view.graph, edge.to)
  const loopy = edge.from === edge.to
  const messages = view.problems.get(edge.id) || []

  return panel(loopy ? "Loop" : "Arrow", loopy ? `${from.label} runs again` : `${from.label} → ${to.label}`, [
    problemsList(messages),
    el("div", {class: "grid grid-cols-2 gap-2"}, [endSelect(edge, "from", view, actions), endSelect(edge, "to", view, actions)]),
    conditionControl(edge, from, view, actions),
    field(
      loopy ? "Runs in a row" : "At most",
      el("input", {
        id: "wf-inspector-iterations",
        type: "number",
        min: "1",
        step: "1",
        class: "input input-sm w-28",
        value: edge.iterations ?? "",
        placeholder: loopy ? "2" : "no limit",
        onchange: (event) => {
          const value = parseInt(event.target.value, 10)
          actions.updateEdge(edge.id, {iterations: value >= 1 ? value : null})
        },
        onkeydown: (event) => event.key === "Enter" && event.target.blur(),
      }),
      loopy
        ? `How many times ${from.label} runs in a row (e.g. 2 = it runs twice).`
        : "How often a task may take this arrow; arrows back to an earlier block need it.",
    ),
    loopy
      ? null
      : el("div", {class: "wf-note", id: "wf-inspector-dots"}, edge.pinned
          ? [
              "Its dots stay where you attached them when blocks move. ",
              el("button", {
                type: "button",
                id: "wf-inspector-unpin",
                class: "wf-link",
                onclick: () => actions.unpin(edge.id),
              }, "Let the editor pick them"),
            ]
          : ["It runs between the sides its blocks face each other with. Drag an end onto another dot to choose one yourself."]),
    el("div", {class: "wf-panel-actions"}, [
      el("button", {type: "button", id: "wf-inspector-delete", class: "btn btn-ghost btn-sm text-error hover:bg-error/10", onclick: actions.remove}, [
        icon("hero-trash-micro"),
        loopy ? "Delete loop" : "Delete arrow",
      ]),
    ]),
  ])
}

// Re-attaches an end without the mouse; the canvas's end handles do the same by dragging.
function endSelect(edge, end, view, actions) {
  const current = edge[end]
  return field(
    end === "from" ? "From" : "To",
    el(
      "select",
      {
        id: `wf-inspector-${end}`,
        class: "select select-sm w-full",
        onchange: (event) => actions.retarget(edge.id, end, event.target.value),
      },
      [...view.graph.nodes]
        .sort((a, b) => a.label.localeCompare(b.label))
        .map((node) => option(node.id, isGroup(node) ? `${node.label} (group)` : node.label, node.id === current)),
    ),
  )
}

function manyPanel(view, actions) {
  const {nodes, edges} = view.selection
  const parts = [nodes.size && `${nodes.size} ${nodes.size === 1 ? "block" : "blocks"}`, edges.size && `${edges.size} ${edges.size === 1 ? "arrow" : "arrows"}`]
  return panel("Selection", parts.filter(Boolean).join(", "), [
    el("p", {class: "wf-note", text: "Drag any of them to move them together. Shift-click adds or removes one."}),
    el("div", {class: "wf-panel-actions"}, [
      nodes.size
        ? el("button", {type: "button", id: "wf-inspector-group", class: "btn btn-ghost btn-sm", onclick: actions.group}, [icon("hero-rectangle-group-micro"), "Group"])
        : null,
      nodes.size
        ? el("button", {type: "button", class: "btn btn-ghost btn-sm", onclick: actions.duplicate}, [icon("hero-document-duplicate-micro"), "Duplicate"])
        : null,
      el("button", {type: "button", id: "wf-inspector-delete", class: "btn btn-ghost btn-sm text-error hover:bg-error/10", onclick: actions.remove}, [
        icon("hero-trash-micro"),
        "Delete",
      ]),
    ]),
  ])
}

function firstSteps() {
  return panel("Workflow", "Nothing here yet", [
    el("ol", {class: "wf-steps", id: "wf-first-steps"}, [
      step("Add a first block", "Drag one from the left, double-click the canvas, or focus one and press Enter. Tasks start there."),
      step("Connect it", "Drag from a block's dot onto another block, or drop a new block right onto a dot."),
      step("Say when", "Pick the outcome each arrow follows; a human block's arrows are its buttons."),
      step("Save", "⌘S. It saves with problems too, as a draft tasks can't run yet."),
    ]),
  ])
}

function step(title, text) {
  return el("li", {}, [el("span", {class: "font-medium text-base-content", text: title}), el("span", {class: "block", text})])
}

function overviewPanel(view, actions) {
  if (view.graph.nodes.length === 0) return firstSteps()
  const blocks = view.graph.nodes.filter((node) => !isGroup(node)).length
  const all = [...view.problems.entries()].flatMap(([id, messages]) => messages.map((message) => ({id, message})))

  return panel("Workflow", `${blocks} ${blocks === 1 ? "block" : "blocks"} · ${view.graph.edges.length} ${view.graph.edges.length === 1 ? "arrow" : "arrows"}`, [
    el("div", {class: "wf-field", id: "wf-problems"}, [
      el("span", {class: "wf-field-label", text: all.length ? `Problems (${all.length})` : "Problems"}),
      all.length === 0
        ? el("p", {class: "wf-ok", id: "wf-no-problems"}, [icon("hero-check-circle-micro", "size-4"), "Nothing to fix. Tasks can run it."])
        : null,
      all.length === 0
        ? null
        : el("p", {class: "wf-note", id: "wf-draft-note"}, "Tasks can't run this workflow until these are fixed. Saving keeps it as a draft meanwhile."),
      all.length === 0
        ? null
        : el(
            "ul",
            {class: "space-y-1"},
            all.map(({id, message}) => {
              const item = id && (findNode(view.graph, id) || findEdge(view.graph, id))
              const name = item ? (item.label ? item.label : arrowName(view.graph, item)) : "Workflow"
              return el("li", {}, [
                el(
                  "button",
                  {
                    type: "button",
                    class: "wf-problem-row",
                    disabled: !item,
                    dataset: {problemFor: id || ""},
                    onclick: () => item && actions.reveal(id),
                  },
                  [icon("hero-exclamation-circle-micro", "size-4 text-error"), el("span", {}, [el("span", {class: "font-medium", text: name}), el("span", {class: "block text-(--orpheus-text-secondary)", text: message})])],
                ),
              ])
            }),
          ),
    ]),
    el("div", {class: "wf-field"}, [
      el("span", {class: "wf-field-label", text: "How to"}),
      el("ul", {class: "wf-tips"}, [
        tip("Add", "drag from the left, double-click the canvas, or focus one and press Enter"),
        tip("Connect", "drag from a block's dot onto another block, or drop a new block onto a dot"),
        tip("Loop", "drop an arrow back onto its own block"),
        tip("Group", "⇧ drag around blocks, then ⌘G"),
        tip("Pan", "drag the canvas or scroll · space drag"),
        tip("Zoom", "pinch · ⌘ scroll · + / −"),
        tip("Undo", "⌘Z · redo ⇧⌘Z · save ⌘S"),
      ]),
    ]),
  ])
}

function tip(title, text) {
  return el("li", {}, [el("span", {class: "font-medium text-base-content", text: title}), ` — ${text}`])
}

function arrowName(graph, edge) {
  const from = findNode(graph, edge.from)
  const to = findNode(graph, edge.to)
  return `${from?.label || "?"} → ${to?.label || "?"}`
}
