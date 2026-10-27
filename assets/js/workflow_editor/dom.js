// A small element builder, so the editor never pastes text into innerHTML.
export function el(tag, props = {}, children = []) {
  const node = document.createElement(tag)
  for (const [key, value] of Object.entries(props)) {
    if (value === undefined || value === null || value === false) continue
    if (key === "class") node.className = value
    else if (key === "text") node.textContent = value
    else if (key === "dataset") Object.assign(node.dataset, value)
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value)
    else if (key === "value") node.value = value
    else if (key === "checked" || key === "selected" || key === "disabled") node[key] = Boolean(value)
    else node.setAttribute(key, value === true ? "" : value)
  }
  for (const child of [].concat(children)) {
    if (child === null || child === undefined || child === false) continue
    node.append(child instanceof Node ? child : document.createTextNode(String(child)))
  }
  return node
}

export function icon(name, size = "size-4") {
  return el("span", {class: `${name} ${size} shrink-0`, "aria-hidden": "true"})
}

const SVG = "http://www.w3.org/2000/svg"

export function svg(tag, attrs = {}) {
  const node = document.createElementNS(SVG, tag)
  for (const [key, value] of Object.entries(attrs)) {
    if (value !== undefined && value !== null) node.setAttribute(key, value)
  }
  return node
}

// Whether keys typed now belong to a form field rather than to the canvas.
export function typing(target) {
  return Boolean(target.closest?.("input, textarea, select, [contenteditable=true]"))
}
