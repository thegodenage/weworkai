// The /workflows/:id canvas (WeworkaiWeb.WorkflowLive). The hook only hands its element
// to the editor; editor.js and the modules it imports do the work.
import {createEditor} from "./editor.js"

export default {
  mounted() {
    this.editor = createEditor(this)
  },

  destroyed() {
    this.editor.destroy()
  },
}
