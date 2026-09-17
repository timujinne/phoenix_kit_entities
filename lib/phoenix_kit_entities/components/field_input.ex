defmodule PhoenixKitEntities.Components.FieldInput do
  @moduledoc """
  Control-only inline renderer for ONE entity field — the embeddable
  primitive under `FormBuilder.build_field/3`'s full form blocks. Hosts
  that lay records out their own way (compact rows, table cells, chips)
  render `<.field_input>` per field and keep full ownership of layout,
  labels, and persistence, while every field type — including ones added
  to entities later — renders correctly without host changes.

  ## The save contract

  The host wraps its inputs in a `<form id="..." phx-change="..." phx-submit="...">`
  it owns (include hidden inputs for row identity — a record uuid — and
  read `_target` to know which field changed). **`phx-submit` is
  load-bearing even when the change event does all the saving**: a form
  with `phx-change` but no `phx-submit` is treated as external by
  LiveView, so Enter in a typed input native-submits and navigates away,
  killing the socket. Point it anywhere harmless — a clause that no-ops
  on payloads without `_target` works.

    * **Typed inputs** (text, textarea, email, url, rich_text, number,
      date) carry `phx-debounce="blur"`, so the form's change event
      fires on blur/enter — not per keystroke.
    * **Discrete inputs** (boolean toggle, select, radio, checkbox
      group) fire immediately. Booleans pair the checkbox with a hidden
      `"false"` input and checkbox groups a hidden `""`, so the change
      payload always carries the key even when everything is unticked.
      Checkbox groups submit under `name[]` (not the bare `name`), so
      the host reads a **list** at that key — `cast_field/2` normalizes
      it, dropping the hidden `""` entry.
    * **Media references** (image, video) are not form inputs at all:
      they render the current file (thumbnail for images) plus
      Choose/Clear buttons that push the host's `on_pick`/`on_clear`
      events with `phx-value-field={field key}` and any `pick_params`.
      The host opens its media picker (e.g. core's `MediaSelectorModal`)
      and writes the chosen storage file uuid through its own save path.

  Cast the change payload with `PhoenixKitEntities.FormBuilder.cast_field/2`
  before persisting — it applies the same per-type coercion and
  validation the full form pipeline uses.

  Nested forms are invalid HTML: this component renders bare controls
  precisely so it can live inside whatever form (or none) the host has;
  the host is responsible for the form context.

  ## Example

      <form
        id={"row-\#{value.uuid}"}
        phx-change="extras_changed"
        phx-submit="extras_changed"
      >
        <input type="hidden" name="uuid" value={value.uuid} />
        <.field_input
          :for={field <- @entity.fields_definition}
          field={field}
          name={"extras[\#{field["key"]}]"}
          value={value.data[field["key"]]}
          size="xs"
          on_pick="pick_extra_media"
          on_clear="clear_extra_media"
          pick_params={%{"uuid" => value.uuid}}
        />
      </form>
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitEntities.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitEntities.FieldTypes

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Number

  @doc """
  Renders the control for one field definition. See the moduledoc for
  the save contract per field-type family.
  """
  attr(:field, :map, required: true, doc: "one fields_definition entry (string keys)")

  attr(:name, :string,
    required: true,
    doc: """
    form input name, e.g. extras[price]. Checkbox groups append `[]`
    (real options and the hidden `""` fallback both submit under
    `name[]`), so the host reads a list at that key.
    """
  )

  attr(:value, :any, default: nil)
  attr(:id, :string, default: nil, doc: "derived from name when absent")
  attr(:size, :string, default: "sm", values: ~w(xs sm md))
  attr(:disabled, :boolean, default: false)

  attr(:class, :string,
    default: nil,
    doc:
      "extra classes merged onto the styled control — for daisyUI modifiers or " <>
        "layout the host owns, e.g. `join-item` when the field sits inside a joined group"
  )

  attr(:form, :string,
    default: nil,
    doc: """
    id of the owning <form> when the control renders OUTSIDE it (the
    HTML form attribute) — e.g. table layouts, where a <form> inside
    <tr> gets foster-parented out by the HTML parser. Applied to every
    native control including the hidden fallbacks.
    """
  )

  attr(:on_pick, :string,
    default: nil,
    doc: "event pushed by the image/video Choose button (required for those types)"
  )

  attr(:on_clear, :string,
    default: nil,
    doc: "event pushed by the image/video Clear button (hidden when absent)"
  )

  attr(:pick_params, :map,
    default: %{},
    doc: """
    extra phx-value-* params on the pick/clear buttons (row identity).
    `"field"` is reserved — the buttons always send the field key under
    it, so a `pick_params` entry named `field` is dropped.
    """
  )

  def field_input(%{field: %{"type" => type}} = assigns) do
    assigns =
      assigns
      |> assign(:type, type)
      |> assign_new(:input_id, fn %{id: id, name: name} ->
        id || "field-input-" <> String.replace(name, ~r/[^A-Za-z0-9_-]+/, "-")
      end)
      |> assign(:pick_attrs, pick_attrs(assigns))

    render_input(assigns)
  end

  # fields_definition entries are string-keyed; anything else (atom keys,
  # missing "type") degrades to the unsupported-type note instead of
  # raising a FunctionClauseError out of the host's render.
  def field_input(assigns) do
    assigns = assign(assigns, :type, malformed_type(assigns.field))

    ~H"""
    <span id={@id} class="text-xs text-base-content/40 italic">
      {gettext("Unsupported field type: %{type}", type: @type)}
    </span>
    """
  end

  defp render_input(%{type: t} = assigns) when t in ["text", "email", "url"] do
    ~H"""
    <input
      type={@type}
      id={@input_id}
      name={@name}
      value={@value}
      form={@form}
      placeholder={@field["placeholder"]}
      disabled={@disabled}
      phx-debounce="blur"
      class={["input input-bordered bg-base-100", size_class("input", @size), @class]}
    />
    """
  end

  defp render_input(%{type: t} = assigns) when t in ["textarea", "rich_text"] do
    ~H"""
    <textarea
      id={@input_id}
      name={@name}
      form={@form}
      placeholder={@field["placeholder"]}
      disabled={@disabled}
      rows="2"
      phx-debounce="blur"
      class={["textarea textarea-bordered bg-base-100", size_class("textarea", @size), @class]}
    >{@value}</textarea>
    """
  end

  # Number/decimal — bounds (`min`/`max`) are enforced server-side by
  # `FormBuilder.cast_field/2`, not through browser constraint
  # validation (that's the whole reason this renders free text, not
  # `<input type="number">`). A bare `<input>`, not `<.decimal_input>`:
  # that component wraps its control in a `<div phx-feedback-for>`,
  # which would nest the actual control one level deeper than every
  # other type in this file — breaking, for these two types only, the
  # moduledoc's `class="join-item"` example (a `.join` container needs
  # the input as a direct child, not a div around it).
  defp render_input(%{type: "number"} = assigns) do
    assigns = assign(assigns, :text_value, Number.format_decimal(assigns.value))
    render_decimal_text_input(assigns)
  end

  defp render_input(%{type: "decimal"} = assigns) do
    decimal_value = FieldTypes.decimal_input_value(assigns.value)
    assigns = assign(assigns, :text_value, Number.format_decimal(decimal_value))
    render_decimal_text_input(assigns)
  end

  defp render_input(%{type: "date"} = assigns) do
    ~H"""
    <input
      type="date"
      id={@input_id}
      name={@name}
      value={@value}
      form={@form}
      disabled={@disabled}
      phx-debounce="blur"
      class={["input input-bordered bg-base-100", size_class("input", @size), @class]}
    />
    """
  end

  # The hidden "false" makes an untick still submit the key — without
  # it the change payload simply omits unchecked checkboxes and the
  # host cannot distinguish "turned off" from "not present".
  defp render_input(%{type: "boolean"} = assigns) do
    ~H"""
    <span class="inline-flex items-center">
      <input type="hidden" name={@name} value="false" form={@form} disabled={@disabled} />
      <input
        type="checkbox"
        id={@input_id}
        name={@name}
        value="true"
        form={@form}
        checked={@value in [true, "true"]}
        disabled={@disabled}
        class={["toggle", size_class("toggle", @size)]}
      />
    </span>
    """
  end

  defp render_input(%{type: "select"} = assigns) do
    ~H"""
    <select
      id={@input_id}
      name={@name}
      form={@form}
      disabled={@disabled}
      class={["select select-bordered bg-base-100", size_class("select", @size), @class]}
    >
      <option value="">{gettext("—")}</option>
      <option
        :for={option <- @field["options"] || []}
        value={option}
        selected={to_string(@value) == to_string(option)}
      >
        {option}
      </option>
    </select>
    """
  end

  # Radios submit nothing when none is picked — the hidden "" keeps the
  # key present, same trick as boolean above. The hidden fallbacks share
  # the control's disabled state: a disabled group must submit NOTHING,
  # or the fallback alone would post "" and silently clear the stored
  # value on the host's next change event.
  defp render_input(%{type: "radio"} = assigns) do
    ~H"""
    <span id={@input_id} class="inline-flex flex-wrap items-center gap-2">
      <input type="hidden" name={@name} value="" form={@form} disabled={@disabled} />
      <label
        :for={option <- @field["options"] || []}
        class="inline-flex items-center gap-1 cursor-pointer text-sm"
      >
        <input
          type="radio"
          name={@name}
          value={option}
          form={@form}
          checked={to_string(@value) == to_string(option)}
          disabled={@disabled}
          class={["radio", size_class("radio", @size)]}
        />
        {option}
      </label>
    </span>
    """
  end

  defp render_input(%{type: "checkbox"} = assigns) do
    assigns = assign(assigns, :selected, List.wrap(assigns.value))

    ~H"""
    <span id={@input_id} class="inline-flex flex-wrap items-center gap-2">
      <input type="hidden" name={@name <> "[]"} value="" form={@form} disabled={@disabled} />
      <label
        :for={option <- @field["options"] || []}
        class="inline-flex items-center gap-1 cursor-pointer text-sm"
      >
        <input
          type="checkbox"
          name={@name <> "[]"}
          value={option}
          form={@form}
          checked={option in @selected}
          disabled={@disabled}
          class={["checkbox", size_class("checkbox", @size)]}
        />
        {option}
      </label>
    </span>
    """
  end

  defp render_input(%{type: t} = assigns) when t in ["image", "video"] do
    ~H"""
    <span id={@input_id} class="inline-flex items-center gap-2">
      <%= if valid_media_ref?(@value) do %>
        <img
          :if={@type == "image"}
          src={URLSigner.signed_url(@value, "thumbnail")}
          alt={@field["label"]}
          class={["object-cover rounded border border-base-content/10", thumb_class(@size)]}
        />
        <.icon :if={@type == "video"} name="hero-video-camera" class="w-5 h-5 text-base-content/60" />
      <% end %>
      <button
        :if={@on_pick}
        type="button"
        phx-click={@on_pick}
        phx-value-field={@field["key"]}
        phx-disable-with={gettext("…")}
        disabled={@disabled}
        class={["btn btn-outline", size_class("btn", @size)]}
        {@pick_attrs}
      >
        <.icon
          name={if @type == "image", do: "hero-photo", else: "hero-video-camera"}
          class="w-3.5 h-3.5"
        />
        {if valid_media_ref?(@value),
          do: gettext("Change"),
          else: gettext("Choose")}
      </button>
      <button
        :if={@on_clear && valid_media_ref?(@value)}
        type="button"
        phx-click={@on_clear}
        phx-value-field={@field["key"]}
        phx-disable-with={gettext("…")}
        disabled={@disabled}
        class={["btn btn-ghost px-1", size_class("btn", @size)]}
        title={gettext("Clear")}
        {@pick_attrs}
      >
        <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
      </button>
    </span>
    """
  end

  # heading carries no data; unknown types (relation, future additions
  # this version doesn't know) degrade to a muted note instead of
  # crashing the host's page.
  defp render_input(%{type: "heading"} = assigns), do: ~H""

  defp render_input(assigns) do
    ~H"""
    <span id={@input_id} class="text-xs text-base-content/40 italic">
      {gettext("Unsupported field type: %{type}", type: @type)}
    </span>
    """
  end

  # Shared markup for the "number"/"decimal" `render_input/1` clauses
  # above.
  defp render_decimal_text_input(assigns) do
    ~H"""
    <input
      type="text"
      inputmode="decimal"
      autocomplete="off"
      id={@input_id}
      name={@name}
      value={@text_value}
      form={@form}
      placeholder={@field["placeholder"]}
      disabled={@disabled}
      phx-debounce="blur"
      class={["input input-bordered bg-base-100", size_class("input", @size), @class]}
    />
    """
  end

  # Best-effort type name for the malformed-field degradation note.
  defp malformed_type(%{type: t}) when is_binary(t), do: t
  defp malformed_type(_), do: "unknown"

  # Render-time guard: the value normally passed the write-path gates,
  # but this component renders whatever the host hands it — a junk
  # binary must degrade to "Choose", never reach URLSigner.
  defp valid_media_ref?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_media_ref?(_), do: false

  defp pick_attrs(%{pick_params: params}) when is_map(params) do
    # "field" is reserved: the buttons render phx-value-field={field key}
    # explicitly, and a same-named pick_params entry would silently
    # override it (attribute spreads win over earlier literal attrs).
    params
    |> Map.drop(["field", :field])
    |> Map.new(fn {k, v} -> {"phx-value-#{k}", v} end)
  end

  defp pick_attrs(_), do: %{}

  defp size_class(base, "xs"), do: base <> "-xs"
  defp size_class(base, "sm"), do: base <> "-sm"
  defp size_class(_base, _md), do: nil

  defp thumb_class("xs"), do: "w-6 h-6"
  defp thumb_class("sm"), do: "w-8 h-8"
  defp thumb_class(_), do: "w-12 h-12"
end
