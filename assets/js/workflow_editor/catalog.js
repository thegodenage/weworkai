// What blocks can name (employees, roles, columns) and what their arrows can say, from the
// catalog the server renders into the page (WorkflowLive.catalog/1).

const ROLE_TONES = {planner: "violet", coder: "blue", reviewer: "amber", qa: "sky", merger: "green", custom: "slate"}
const ENDING_COLUMNS = ["done", "canceled"]

export const DECISION_SUGGESTIONS = ["accepted", "not accepted", "approved", "continue", "changes requested"]

export function initials(name) {
  return name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((word) => word[0])
    .join("")
    .toUpperCase()
}

export function createCatalog({employees, roles, columns, colors, triage_outcomes: triageOutcomes}) {
  const employee = new Map(employees.map((one) => [one.id, one]))
  const role = new Map(roles.map((one) => [one.value, one]))
  const column = new Map(columns.map((one) => [one.value, one]))

  const agents = employees.filter((one) => one.kind === "agent")
  const humans = employees.filter((one) => one.kind === "human")
  const agentOf = (node) => (node.employee_id ? employee.get(node.employee_id) : null)

  // An agent block's role: its own, or its agent's; null once its agent was removed.
  const roleOf = (node) => {
    if (node.kind !== "agent") return null
    if (node.agent_role) return node.agent_role
    const agent = agentOf(node)
    return agent && agent.kind === "agent" ? agent.role : null
  }

  const roleLabel = (value) => role.get(value)?.label || value

  function describe(node) {
    switch (node.kind) {
      case "agent": {
        const agent = agentOf(node)
        // A merger block's target branch, when it names one.
        const into = roleOf(node) === "merger" && node.merge_branch ? ` → ${node.merge_branch}` : ""
        if (agent && agent.kind === "agent") {
          return {subtitle: `${roleLabel(agent.role)}${into}`, tone: ROLE_TONES[agent.role], avatar: initials(agent.name)}
        }
        if (node.agent_role) {
          return {
            subtitle: `Any ${roleLabel(node.agent_role).toLowerCase()}${into}`,
            tone: ROLE_TONES[node.agent_role],
            icon: "hero-cpu-chip-micro",
          }
        }
        return {subtitle: "Its agent was removed", tone: "red", icon: "hero-exclamation-triangle-micro"}
      }
      case "human": {
        const person = node.employee_id && employee.get(node.employee_id)
        if (person) return {subtitle: person.title || "Human", tone: "green", avatar: initials(person.name)}
        if (node.employee_id) return {subtitle: "Person removed", tone: "red", icon: "hero-exclamation-triangle-micro"}
        return {subtitle: "Any human decides", tone: "green", icon: "hero-user-micro"}
      }
      case "column": {
        const label = column.get(node.column_status)?.label || "a column"
        const ends = ENDING_COLUMNS.includes(node.column_status)
        return {
          subtitle: ends ? `${label} · ends the workflow` : `Moves the task to ${label}`,
          tone: node.column_status === "done" ? "green" : node.column_status === "canceled" ? "red" : "slate",
          icon: ends ? "hero-flag-micro" : "hero-view-columns-micro",
        }
      }
      case "triage":
        return {subtitle: "Routes by worst severity", tone: "amber", icon: "hero-funnel-micro"}
      default:
        return {subtitle: "Group", tone: "violet", icon: "hero-rectangle-group-micro"}
    }
  }

  // The conditions an arrow out of the node can name: a list to pick from, or null when any
  // name goes (a human's decision; a group's arrows carry its blocks' outcomes).
  function outcomes(node) {
    if (node.kind === "agent") return role.get(roleOf(node))?.outcomes || null
    if (node.kind === "column") return []
    if (node.kind === "triage") return triageOutcomes
    return null
  }

  function kindLabel(node) {
    return {agent: "Agent", human: "Human", column: "Column", group: "Group", triage: "Triage"}[node.kind]
  }

  return {
    agents,
    humans,
    roles,
    columns,
    colors,
    employee: (id) => employee.get(id),
    roleOf,
    roleLabel,
    describe,
    outcomes,
    kindLabel,
    allOutcomes: [...new Set([...roles.flatMap((one) => one.outcomes), ...triageOutcomes])],
    columnLabel: (value) => column.get(value)?.label || value,
  }
}
