defmodule WeworkaiWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: WeworkaiWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "hard-shadow flex w-80 max-w-80 items-start gap-3 border border-l-4 border-(--orpheus-border-strong) bg-(--orpheus-card) p-3 text-sm text-wrap sm:w-96 sm:max-w-96",
        @kind == :info && "border-l-info",
        @kind == :error && "border-l-error"
      ]}>
        <div class="min-w-0 flex-1">
          <p class={[
            "orpheus-badge mb-1",
            @kind == :info && "tone-blue",
            @kind == :error && "tone-red"
          ]}>
            {@kind}
          </p>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p class="text-(--orpheus-text-secondary)">{msg}</p>
        </div>
        <button type="button" class="group cursor-pointer self-start" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-4 opacity-50 group-hover:opacity-100" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a section heading as a micro-label run out to a dashed rule, with an optional
  count at its end: `WORKING AGENTS - - - - [03]`.

  ## Examples

      <.section_label count={length(@runs)}>Working agents</.section_label>
  """
  attr :count, :integer, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def section_label(assigns) do
    ~H"""
    <h2 class={["micro-label flex items-center gap-3", @class]}>
      <span>{render_slot(@inner_block)}</span>
      <span class="h-px flex-1 border-t border-dashed border-(--orpheus-border)"></span>
      <span :if={@count} class="tabular-nums">
        [{@count |> Integer.to_string() |> String.pad_leading(2, "0")}]
      </span>
    </h2>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"
  attr :row_class, :any, default: nil, doc: "the function for generating each row's class"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="orpheus-card overflow-x-auto">
      <table class="orpheus-table">
        <thead>
          <tr>
            <th :for={col <- @col}>{col[:label]}</th>
            <th :if={@action != []}>
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)} class={@row_class && @row_class.(row)}>
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={@row_click && "hover:cursor-pointer"}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 font-medium">
              <div class="flex gap-4">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders Previous / Next links around "Page X of Y". Hidden when there is one page.

  ## Examples

      <.pagination page_number={@page_number} page_count={@page_count} path={&list_path/1} />
  """
  attr :page_number, :integer, required: true
  attr :page_count, :integer, required: true
  attr :path, :any, required: true, doc: "function from a page number to its URL"

  def pagination(assigns) do
    ~H"""
    <nav
      :if={@page_count > 1}
      aria-label="Pagination"
      class="mt-4 flex items-center justify-end gap-3 text-sm"
    >
      <.link :if={@page_number > 1} patch={@path.(@page_number - 1)} class="btn btn-ghost btn-xs">
        Previous
      </.link>
      <span class="micro-label tabular-nums">Page {@page_number} of {@page_count}</span>
      <.link
        :if={@page_number < @page_count}
        patch={@path.(@page_number + 1)}
        class="btn btn-ghost btn-xs"
      >
        Next
      </.link>
    </nav>
    """
  end

  @doc """
  Renders a centered modal dialog. Escape and clicking outside run `on_cancel`.

  ## Examples

      <.modal :if={@form} id="task-modal" on_cancel={JS.patch(~p"/")}>
        <:title>New task</:title>
        ...
      </.modal>
  """
  attr :id, :string, required: true
  attr :on_cancel, JS, required: true
  slot :title, required: true
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-(--orpheus-overlay) px-4 pt-[15vh] pb-8 backdrop-blur-sm"
      phx-window-keydown={@on_cancel}
      phx-key="escape"
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
        class="orpheus-card hard-shadow w-full max-w-lg border-(--orpheus-border-strong) p-6"
        phx-click-away={@on_cancel}
      >
        <h2
          id={"#{@id}-title"}
          class="-mx-6 -mt-6 mb-5 border-b border-(--orpheus-border) bg-base-200 px-6 py-3 text-xs font-semibold tracking-[0.1em] uppercase"
        >
          {render_slot(@title)}
        </h2>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @agent_tones ~w(sky blue violet amber green red)

  @doc """
  Renders an employee's initial. Agents get a colored oval, stable per id; humans a neutral circle.
  """
  attr :employee, :map, required: true
  attr :class, :any, default: nil

  def avatar(assigns) do
    ~H"""
    <span
      title={@employee.name}
      class={[
        "inline-flex shrink-0 items-center justify-center text-xs font-semibold select-none",
        if(@employee.kind == :agent,
          do: "h-6 w-8 bg-(--tone) text-base-100 tone-#{agent_tone(@employee.id)}",
          else: "size-6 border border-(--orpheus-border-strong) text-(--orpheus-text-secondary)"
        ),
        @class
      ]}
    >
      {@employee.name |> String.first() |> String.upcase()}
    </span>
    """
  end

  defp agent_tone(id), do: Enum.at(@agent_tones, :erlang.phash2(id, length(@agent_tones)))

  @doc """
  Renders markdown as sanitized HTML.

  `files` maps attached file names to their URLs, so `![shot.png](shot.png)` shows the attachment.
  """
  attr :content, :string, default: nil
  attr :class, :any, default: nil
  attr :files, :map, default: %{}

  def markdown(assigns) do
    ~H"""
    <div class={["markdown", @class]}>
      {Phoenix.HTML.raw(
        MDEx.to_html!(link_files(@content || "", @files),
          sanitize: MDEx.Document.default_sanitize_options()
        )
      )}
    </div>
    """
  end

  defp link_files(content, files) do
    Enum.reduce(files, content, fn {name, url}, content ->
      String.replace(content, "](#{name})", "](#{url})")
    end)
  end

  @markdown_tools [
    {"hero-h2-micro", "Heading", "## ", ""},
    {"hero-bold-micro", "Bold", "**", "**"},
    {"hero-italic-micro", "Italic", "_", "_"},
    {"hero-list-bullet-micro", "Bulleted list", "- ", ""},
    {"hero-numbered-list-micro", "Numbered list", "1. ", ""},
    {"hero-code-bracket-micro", "Code", "`", "`"},
    {"hero-link-micro", "Link", "[", "](url)"}
  ]

  @doc """
  Renders a markdown textarea with a formatting toolbar and a Write/Preview switch.
  The preview renders `field.value` server-side, so it is as fresh as the form's last phx-change.

  With an `upload`, images pasted into the textarea (a screenshot on ⌘V) go to that upload, and
  a `![name](name)` reference to each goes in at the cursor. `files` (see `markdown/1`) lets the
  preview show the ones already attached.
  """
  attr :id, :string, required: true
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, default: nil
  attr :upload, Phoenix.LiveView.UploadConfig, default: nil
  attr :files, :map, default: %{}
  attr :rest, :global, include: ~w(placeholder rows phx-debounce)

  def markdown_editor(assigns) do
    assigns = assign(assigns, :tools, @markdown_tools)

    ~H"""
    <div
      id={@id}
      class="fieldset mb-2"
      phx-hook=".MarkdownEditor"
      data-upload={@upload && @upload.name}
    >
      <span :if={@label} class="label mb-1">{@label}</span>
      <div class="rounded-md border border-(--orpheus-border) bg-base-200 focus-within:border-primary">
        <div class="flex items-center gap-1 border-b border-(--orpheus-border) px-1 py-1">
          <button
            id={"#{@id}-write-tab"}
            type="button"
            class="btn btn-ghost btn-xs btn-active"
            phx-click={markdown_tab(@id, :write)}
          >
            Write
          </button>
          <button
            id={"#{@id}-preview-tab"}
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click={markdown_tab(@id, :preview)}
          >
            Preview
          </button>
          <div id={"#{@id}-toolbar"} class="ml-auto flex">
            <button
              :for={{icon, label, prefix, suffix} <- @tools}
              type="button"
              data-before={prefix}
              data-after={suffix}
              aria-label={label}
              title={label}
              class="btn btn-ghost btn-xs btn-square"
            >
              <.icon name={icon} class="size-4" />
            </button>
          </div>
        </div>
        <textarea
          id={"#{@id}-input"}
          name={@field.name}
          class="block w-full resize-y bg-transparent px-3 py-2 text-sm outline-none"
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @field.value)}</textarea>
        <div id={"#{@id}-preview"} class="hidden min-h-24 px-3 py-2 text-sm">
          <.markdown :if={@field.value not in [nil, ""]} content={@field.value} files={@files} />
          <p :if={@field.value in [nil, ""]} class="text-(--orpheus-text-muted)">
            Nothing to preview
          </p>
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".MarkdownEditor">
      export default {
        mounted() {
          const textarea = this.el.querySelector("textarea")

          this.el.addEventListener("click", (event) => {
            const button = event.target.closest("[data-before]")
            if (!button) return
            const {selectionStart: start, selectionEnd: end, value} = textarea
            const {before, after} = button.dataset
            textarea.value = value.slice(0, start) + before + value.slice(start, end) + after + value.slice(end)
            textarea.focus()
            textarea.setSelectionRange(start + before.length, end + before.length)
            // Programmatic edits don't fire input; LiveView needs it to see the change.
            textarea.dispatchEvent(new Event("input", {bubbles: true}))
          })

          textarea.addEventListener("paste", (event) => {
            const upload = this.el.dataset.upload
            const clipboard = event.clipboardData
            if (!upload || !clipboard || clipboard.types.includes("text/plain")) return
            const images = Array.from(clipboard.files).filter((file) => file.type.startsWith("image/"))
            if (images.length === 0) return
            event.preventDefault()
            // Every screenshot pastes as "image.png", and a task keeps one file per name.
            const stamp = new Date().toISOString().slice(0, 23).replace("T", "-").replace(/:/g, "").replace(".", "-")
            const named = images.map((file, i) => {
              const ext = file.name.match(/\.[A-Za-z0-9]+$/)?.[0] ?? ""
              const index = images.length > 1 ? `-${i + 1}` : ""
              return new File([file], `screenshot-${stamp}${index}${ext}`, {type: file.type})
            })
            this.upload(upload, named)
            this.replaceSelection(textarea, named.map(({name}) => `![${name}](${name})`).join("\n"))
          })
        },

        replaceSelection(textarea, text) {
          const {selectionStart: start, selectionEnd: end, value} = textarea
          textarea.value = value.slice(0, start) + text + value.slice(end)
          textarea.setSelectionRange(start + text.length, start + text.length)
          // Programmatic edits don't fire input; LiveView needs it to see the change.
          textarea.dispatchEvent(new Event("input", {bubbles: true}))
        },
      }
    </script>
    """
  end

  defp markdown_tab(id, tab) do
    {shown, hidden} = if tab == :write, do: {"write", "preview"}, else: {"preview", "write"}
    panel = %{"write" => "##{id}-input, ##{id}-toolbar", "preview" => "##{id}-preview"}

    JS.show(to: panel[shown])
    |> JS.hide(to: panel[hidden])
    |> JS.add_class("btn-active", to: "##{id}-#{shown}-tab")
    |> JS.remove_class("btn-active", to: "##{id}-#{hidden}-tab")
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(WeworkaiWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(WeworkaiWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
