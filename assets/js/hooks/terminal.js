import {Terminal} from "../../vendor/xterm/xterm.mjs"

// Read-only view of an agent run's log. The server pushes the whole (tail-capped) log as
// plain text, so each update replays it into a fresh screen.
export default {
  mounted() {
    this.terminal = new Terminal({
      cols: 200,
      rows: 50,
      disableStdin: true,
      cursorBlink: false,
      fontFamily: '"JetBrains Mono", "SF Mono", monospace',
      fontSize: 11,
      scrollback: 5000,
      theme: {background: "#0c0c0c", foreground: "#e8e8e3", cursor: "#ff6b2c"},
    })
    this.terminal.open(this.el)
    this.handleEvent("terminal:output", ({output}) => {
      this.terminal.reset()
      // A terminal needs \r\n to return to the first column.
      this.terminal.write(output.replace(/\r?\n/g, "\r\n"))
    })
  },

  destroyed() {
    this.terminal.dispose()
  },
}
