// Undo / redo over whole graphs: each one is immutable, so keeping them is enough.
const LIMIT = 200

export function createHistory(initial) {
  let past = []
  let present = initial
  let future = []

  return {
    get present() {
      return present
    },
    push(graph) {
      past = [...past, present].slice(-LIMIT)
      present = graph
      future = []
    },
    undo() {
      if (past.length === 0) return null
      future = [present, ...future]
      present = past[past.length - 1]
      past = past.slice(0, -1)
      return present
    },
    redo() {
      if (future.length === 0) return null
      past = [...past, present]
      present = future[0]
      future = future.slice(1)
      return present
    },
    // Saving renames the editor's own ids everywhere, so undo keeps pointing at the same things.
    map(transform) {
      past = past.map(transform)
      present = transform(present)
      future = future.map(transform)
    },
    get canUndo() {
      return past.length > 0
    },
    get canRedo() {
      return future.length > 0
    },
  }
}
