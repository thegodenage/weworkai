// The editor's unsaved graph, kept per tab (sessionStorage) so a reload, a redeploy or a
// LiveView that had to remount loses nothing: the editor offers it back on load. Storage
// can be unavailable (private mode, blocked site data) or full; then there is no draft.
const key = (workflowId) => `wf-draft:${workflowId}`

export function readDraft(workflowId) {
  try {
    const raw = sessionStorage.getItem(key(workflowId))
    return raw ? JSON.parse(raw) : null
  } catch {
    return null
  }
}

// `draft`: {graph, version (the one it was drawn from), at (ms)}.
export function writeDraft(workflowId, draft) {
  try {
    sessionStorage.setItem(key(workflowId), JSON.stringify(draft))
  } catch {
    // No room or no storage: the draft only lives in the page.
  }
}

export function clearDraft(workflowId) {
  try {
    sessionStorage.removeItem(key(workflowId))
  } catch {
    // Nothing was stored.
  }
}
