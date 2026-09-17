defmodule PhoenixKitEntities.FormBuilder do
  @moduledoc """
  Dynamic form builder for entity data forms.

  This module generates Phoenix.Component forms based on entity field definitions,
  enabling dynamic data entry forms that adapt to the entity's schema.

  ## Usage

      # Generate form fields for an entity
      fields_html = PhoenixKitEntities.FormBuilder.build_fields(entity, changeset)

      # Generate a single field
      field_html = PhoenixKitEntities.FormBuilder.build_field(field_definition, changeset)

      # Validate entity data against field definitions
      {:ok, validated_data} = PhoenixKitEntities.FormBuilder.validate_data(entity, data_params)

  ## Field Type Support

  The FormBuilder supports all field types defined in `PhoenixKitEntities.FieldTypes`:

  - **Basic Types**: text, textarea, email, url, rich_text
  - **Numeric Types**: number
  - **Boolean Types**: boolean (toggle/checkbox)
  - **Date Types**: date
  - **Choice Types**: select, radio, checkbox (with options)
  - **Media Types**: image, file (upload)
  - **Relational Types**: relation (entity references)

  ## Form Generation

  Forms are generated as Phoenix.Component HTML with proper validation,
  error handling, and styling consistent with the PhoenixKit design system.

  ## Field-Level Translations (display-only)

  A field definition may carry an optional `"translations"` key, resolved
  by `translated_label/2` and `translated_option_label/3`:

      %{
        "key" => "color",
        "label" => "Värv",
        "type" => "radio",
        "options" => ["Must", "Valge"],
        "translations" => %{
          "ru" => %{"label" => "Цвет", "options" => %{"Must" => "Чёрный", "Valge" => "Белый"}},
          "en" => %{"label" => "Colour", "options" => %{"Must" => "Black", "Valge" => "White"}}
        }
      }

  This is **display-only**: the canonical, stored/submitted value is
  always the original `"label"` / option string (`"Must"`, never
  `"Чёрный"`) — `"translations"` never affects validation,
  `merge_other_params/2`, or what lands in `EntityData.data`. `"heading"`
  fields are translated the same way (their `"translations"` map only
  ever has a `"label"` entry, since headings have no options).

  Resolution falls back to the original text whenever a lookup can't be
  satisfied: `lang_code` is `nil`, the field has no `"translations"` key
  at all, the language isn't present, or (for options) that specific
  option has no translated entry. Language-code lookups tolerate
  base/dialect mismatches the same way entity-level `settings["translations"]`
  does (see `PhoenixKitEntities.get_entity_by_name/2`'s dialect-tolerant
  lookup) — a field translated under `"ru-RU"` still resolves for a
  caller passing the bare `"ru"`, and vice versa.

  ### Which surfaces resolve this

  Resolved wherever `build_fields/3` / `build_field/3` receive a non-nil
  `opts[:lang_code]` (every rendering clause: labels; `select`/`radio`/
  `checkbox` also translate their option text), and by
  `PhoenixKitEntities.Components.LiveDataForm` in both modes — `:edit`
  via `build_fields/3` (it passes its `lang` attr straight through as
  `lang_code`), `:readonly` directly via `translated_label/2` /
  `translated_option_label/3`.

  **Not** resolved — these surfaces render the canonical field text
  regardless of locale, by design; this is a scope boundary, not a bug:

  - `PhoenixKitEntities.Web.DataForm` (the admin record editor) — the
    non-multilang branch calls `build_fields/3` with `lang_code: nil`
    hardcoded; the multilang branch only passes a real locale when the
    multilang module itself is enabled, otherwise also `nil`.
  - `PhoenixKitEntities.Components.EntityForm` (the public entity
    submission form) — doesn't pass `lang_code` to `build_fields/3` at
    all.
  - Validation error messages (`EntityData.changeset/2` and
    `validate_data/3` here) — always interpolate the canonical
    `field_def["label"]` / `field["label"]`, never a translation.
  """

  import Phoenix.Component
  import PhoenixKitWeb.Components.Core.DecimalInput, only: [decimal_input: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.FormFieldLabel, only: [label: 1]
  use Gettext, backend: PhoenixKitEntities.Gettext

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Utils.Format
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.Number
  alias PhoenixKitEntities.FieldTypes

  # Sentinel value for the synthetic "Other" option on radio/select/checkbox
  # fields with `"allow_other" => true`. Submitted alongside a companion
  # `<key>__other` free-text param; `merge_other_params/2` resolves the pair
  # back into the free-text value before validation/storage.
  @other_sentinel "__other__"

  @doc """
  Builds form fields HTML for an entire entity.

  Takes an entity with its field definitions and generates the complete
  form HTML for data entry.

  ## Parameters

  - `entity` - The entity struct with fields_definition
  - `changeset` - The changeset for the entity data
  - `opts` - Optional configuration (default: [])

  ## Options

  - `:wrapper_class` - CSS class for field wrapper divs
  - `:input_class` - CSS class for input elements
  - `:label_class` - CSS class for label elements
  - `:id_prefix` - extra segment folded into each field wrapper's DOM id
    (`"entity-field-\#{id_prefix}-\#{key}-\#{lang}"`). Every page that has
    historically called this function renders exactly one form per entity
    (admin `DataForm`, the public entity form), so the default (`nil`,
    omitted from the id) is unchanged. Pages embedding more than one
    instance of the *same* entity's fields at once — e.g.
    `PhoenixKitEntities.Components.LiveDataForm` used once per record in a
    list — MUST pass something unique per instance (the record's uuid) or
    LiveView raises "Duplicate id found while testing LiveView" (in tests)
    / silently misdirects DOM patches between instances (at runtime).

  ## Examples

      iex> entity = %Entities{fields_definition: [
      ...>   %{"type" => "text", "key" => "title", "label" => "Title", "required" => true}
      ...> ]}
      iex> changeset = Ecto.Changeset.cast(%{}, %{}, [])
      iex> PhoenixKitEntities.FormBuilder.build_fields(entity, changeset)
      # Returns Phoenix.Component form HTML
  """
  def build_fields(entity, changeset, opts \\ []) do
    fields_definition = entity.fields_definition || []
    lang_code = opts[:lang_code]

    # For secondary languages, extract primary data for placeholder text
    opts = maybe_add_primary_placeholders(opts, changeset, entity, lang_code)

    # When multilang: extract language-specific data into a view changeset
    # so all existing build_field/get_field_value calls work unchanged.
    changeset = maybe_apply_language_view(changeset, entity, lang_code)

    assigns = %{
      fields_definition: fields_definition,
      changeset: changeset,
      opts: opts,
      lang_suffix: lang_code || "primary",
      id_prefix: id_prefix_segment(opts[:id_prefix])
    }

    # Each wrapper carries a language-specific id so that switching the
    # language tab causes LiveView's DOM patcher to drop and re-create
    # the input elements — without this, browser-owned input state from
    # the previous tab leaks across (e.g. the user types "Acme" in EN-US,
    # switches to ES, and the ES input still shows "Acme" because the
    # `<input>` matched by id and the new server-rendered value=""
    # doesn't override the live DOM value). `id_prefix` (see moduledoc)
    # additionally scopes it per record instance for pages embedding more
    # than one form for the same entity at once.
    ~H"""
    <div class="space-y-6">
      <%= for field <- @fields_definition do %>
        <div
          class={["form-field-wrapper", @opts[:wrapper_class]]}
          id={"entity-field-#{@id_prefix}#{field["key"]}-#{@lang_suffix}"}
        >
          {build_field(field, @changeset, @opts)}
        </div>
      <% end %>
    </div>
    """
  end

  defp id_prefix_segment(nil), do: ""
  defp id_prefix_segment(prefix), do: "#{prefix}-"

  # When a lang_code is provided, extract that language's RAW (override-only)
  # data and replace the :data field in the changeset so downstream
  # build_field calls read the correct values via get_field_value/2.
  #
  # Important: uses `get_raw_language_data/2` (override-only), NOT
  # `get_language_data/2` (which merges primary into secondary). With the
  # merged form, switching to a secondary tab with no overrides would show
  # the primary values as input values rather than empty fields, defeating
  # the placeholder pattern for non-text fields. The text-field path used
  # to compensate via `inherited_value?/2` but boolean / date / select /
  # radio / checkbox / file inputs read `get_field_value/2` directly and
  # had no such guard, so they incorrectly inherited primary values.
  #
  # On the primary tab `lang_code == primary`, so raw data == primary's
  # data — no behaviour change vs. the merged view.
  defp maybe_apply_language_view(changeset, _entity, nil), do: changeset

  defp maybe_apply_language_view(%Phoenix.HTML.Form{} = form, _entity, lang_code) do
    data = Ecto.Changeset.get_field(form.source, :data)

    if Multilang.multilang_data?(data) do
      lang_data = Multilang.get_raw_language_data(data, lang_code)
      updated_changeset = Ecto.Changeset.put_change(form.source, :data, lang_data)
      %{form | source: updated_changeset}
    else
      form
    end
  end

  defp maybe_apply_language_view(changeset, _entity, lang_code) do
    data = Ecto.Changeset.get_field(changeset, :data)

    if Multilang.multilang_data?(data) do
      lang_data = Multilang.get_raw_language_data(data, lang_code)
      Ecto.Changeset.put_change(changeset, :data, lang_data)
    else
      changeset
    end
  end

  # ── Multilang placeholder helpers ──────────────────────────────

  defp maybe_add_primary_placeholders(opts, _changeset, _entity, nil), do: opts

  defp maybe_add_primary_placeholders(opts, changeset, _entity, lang_code) do
    primary = Multilang.primary_language()

    if lang_code == primary do
      opts
    else
      data = extract_data_from_changeset(changeset)

      if Multilang.multilang_data?(data) do
        primary_data = Multilang.get_primary_data(data)
        Keyword.put(opts, :primary_placeholders, primary_data)
      else
        opts
      end
    end
  end

  defp extract_data_from_changeset(%Phoenix.HTML.Form{} = form),
    do: Ecto.Changeset.get_field(form.source, :data)

  defp extract_data_from_changeset(changeset),
    do: Ecto.Changeset.get_field(changeset, :data)

  defp get_effective_placeholder(field, opts, default \\ "") do
    case opts[:primary_placeholders] do
      %{} = primary_data ->
        primary_value = Map.get(primary_data, field["key"])

        if primary_value != nil and to_string(primary_value) != "" do
          to_string(primary_value)
        else
          field["placeholder"] || default
        end

      _ ->
        field["placeholder"] || default
    end
  end

  # For text-like fields on secondary languages, show empty when value
  # matches primary (inherited) — the primary value appears as placeholder.
  defp get_effective_text_value(changeset, field_key, opts) do
    current = get_field_value(changeset, field_key)

    case opts[:primary_placeholders] do
      %{} = primary_data ->
        primary_value = Map.get(primary_data, field_key)
        if inherited_value?(current, primary_value), do: nil, else: current

      _ ->
        current
    end
  end

  defp inherited_value?(nil, _), do: true
  defp inherited_value?("", _), do: true
  defp inherited_value?(a, b), do: to_string(a) == to_string(b)

  # ── Field-level translations (display-only) ────────────────────

  @doc """
  Resolves a field's (or a `"heading"` field's) display label for
  `lang_code`, honoring an optional `"translations"` key on the field
  definition (see the moduledoc for the full contract).

  Falls back to `field["label"]` whenever `lang_code` is `nil`, the
  field has no `"translations"` map, the language isn't present in it,
  or its `"label"` entry is missing/blank. Display-only — never affects
  the canonical `field["label"]` itself.

  ## Examples

      iex> field = %{"label" => "Värv", "translations" => %{"ru" => %{"label" => "Цвет"}}}
      iex> PhoenixKitEntities.FormBuilder.translated_label(field, "ru")
      "Цвет"

      iex> PhoenixKitEntities.FormBuilder.translated_label(field, "et")
      "Värv"

      iex> PhoenixKitEntities.FormBuilder.translated_label(field, nil)
      "Värv"
  """
  @spec translated_label(map(), String.t() | nil) :: String.t() | nil
  def translated_label(field, lang_code) when is_map(field) do
    case Map.get(lookup_field_translation(field, lang_code), "label") do
      value when is_binary(value) and value != "" -> value
      _ -> field["label"]
    end
  end

  @doc """
  Resolves the display label for a single radio/select/checkbox option
  value, honoring the field's optional `"translations" => %{lang =>
  %{"options" => %{option_value => translated}}}` map.

  `option_value` is always the canonical, stored/submitted string —
  this only affects what text renders next to it (e.g. `<option
  value={option_value}>{translated_option_label(...)}</option>`). Falls
  back to `option_value` itself whenever `lang_code` is `nil`, the field
  has no `"translations"` map, the language isn't present, or this
  specific option has no translated entry (this is also what makes a
  free-text `allow_other` value display as-is: it was never one of the
  fixed options, so it never has a translation entry to find).

  ## Examples

      iex> field = %{"translations" => %{"ru" => %{"options" => %{"Must" => "Чёрный"}}}}
      iex> PhoenixKitEntities.FormBuilder.translated_option_label(field, "Must", "ru")
      "Чёрный"

      iex> PhoenixKitEntities.FormBuilder.translated_option_label(field, "Valge", "ru")
      "Valge"
  """
  @spec translated_option_label(map(), String.t(), String.t() | nil) :: String.t()
  def translated_option_label(field, option_value, lang_code) when is_map(field) do
    case lookup_field_translation(field, lang_code) do
      %{"options" => %{} = options} ->
        case Map.get(options, option_value) do
          value when is_binary(value) and value != "" -> value
          _ -> option_value
        end

      _ ->
        option_value
    end
  end

  defp lookup_field_translation(_field, nil), do: %{}

  defp lookup_field_translation(field, lang_code) when is_binary(lang_code) do
    case field["translations"] do
      %{} = translations -> lookup_translation(translations, lang_code)
      _ -> %{}
    end
  end

  defp lookup_field_translation(_field, _lang_code), do: %{}

  # Looks up a translation entry by locale, tolerating base/dialect
  # mismatches — mirrors `PhoenixKitEntities`'s private `lookup_translation/2`
  # for entity-level `settings["translations"]`.
  #
  # Match priority:
  # 1. Exact key match (`"ru-RU"` -> `"ru-RU"`).
  # 2. Same base code (`"ru"` -> first `"ru-*"` translation, deterministic
  #    via sort).
  defp lookup_translation(translations_map, lang_code) do
    case Map.get(translations_map, lang_code) do
      %{} = exact ->
        exact

      _ ->
        base = safe_extract_base(lang_code)

        translations_map
        |> Enum.filter(fn {key, _v} ->
          is_binary(key) and base != nil and safe_extract_base(key) == base
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> case do
          [{_key, value} | _] when is_map(value) -> value
          _ -> %{}
        end
    end
  end

  defp safe_extract_base(code) when is_binary(code) and code != "" do
    DialectMapper.extract_base(code)
  rescue
    _ -> nil
  end

  defp safe_extract_base(_code), do: nil

  @doc """
  Builds a single form field based on field definition.

  ## Parameters

  - `field` - Field definition map
  - `changeset` - The changeset for validation and values
  - `opts` - Optional configuration

  ## Examples

      iex> field = %{"type" => "text", "key" => "title", "label" => "Title"}
      iex> changeset = Ecto.Changeset.cast(%{}, %{}, [])
      iex> PhoenixKitEntities.FormBuilder.build_field(field, changeset)
      # Returns Phoenix.Component field HTML
  """
  def build_field(field, changeset, opts \\ [])

  # Text Input
  def build_field(%{"type" => "text"} = field, changeset, opts) do
    placeholder = get_effective_placeholder(field, opts)
    value = get_effective_text_value(changeset, field["key"], opts)

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      placeholder: placeholder,
      value: value
    }

    ~H"""
    <div>
      <.label>
        {translated_label(@field, @opts[:lang_code])}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <input
        type="text"
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        value={@value}
        placeholder={@placeholder}
        class={["input w-full", @opts[:input_class]]}
        maxlength={@field["max_length"]}
        required={@field["required"] && !@opts[:primary_placeholders]}
        disabled={@opts[:disabled]}
      />
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="fieldset-label">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Textarea
  def build_field(%{"type" => "textarea"} = field, changeset, opts) do
    placeholder = get_effective_placeholder(field, opts)
    value = get_effective_text_value(changeset, field["key"], opts)

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      placeholder: placeholder,
      value: value
    }

    ~H"""
    <div>
      <.label for={@field["key"]}>
        {translated_label(@field, @opts[:lang_code])}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <textarea
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        placeholder={@placeholder}
        class={["textarea w-full", @opts[:input_class]]}
        rows={@field["rows"] || 4}
        maxlength={@field["max_length"]}
        required={@field["required"] && !@opts[:primary_placeholders]}
        disabled={@opts[:disabled]}
      >{@value}</textarea>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="fieldset-label">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Email Input
  def build_field(%{"type" => "email"} = field, changeset, opts) do
    placeholder = get_effective_placeholder(field, opts, gettext("user@example.com"))
    value = get_effective_text_value(changeset, field["key"], opts)

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      placeholder: placeholder,
      value: value
    }

    ~H"""
    <div>
      <.label for={@field["key"]}>
        {translated_label(@field, @opts[:lang_code])}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <input
        type="email"
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        value={@value}
        placeholder={@placeholder}
        class={["input w-full", @opts[:input_class]]}
        required={@field["required"] && !@opts[:primary_placeholders]}
        disabled={@opts[:disabled]}
      />
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="fieldset-label">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # URL Input
  def build_field(%{"type" => "url"} = field, changeset, opts) do
    placeholder = get_effective_placeholder(field, opts, gettext("https://example.com"))
    value = get_effective_text_value(changeset, field["key"], opts)

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      placeholder: placeholder,
      value: value
    }

    ~H"""
    <div>
      <.label for={@field["key"]}>
        {translated_label(@field, @opts[:lang_code])}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <input
        type="url"
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        value={@value}
        placeholder={@placeholder}
        class={["input w-full", @opts[:input_class]]}
        required={@field["required"] && !@opts[:primary_placeholders]}
        disabled={@opts[:disabled]}
      />
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="fieldset-label">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Rich Text Editor
  def build_field(%{"type" => "rich_text"} = field, changeset, opts) do
    placeholder = get_effective_placeholder(field, opts, gettext("Enter rich text content..."))
    value = get_effective_text_value(changeset, field["key"], opts)

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      placeholder: placeholder,
      value: value
    }

    ~H"""
    <div>
      <.label for={@field["key"]}>
        {translated_label(@field, @opts[:lang_code])}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <textarea
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        placeholder={@placeholder}
        class={["textarea w-full h-32", @opts[:input_class]]}
        rows="8"
        required={@field["required"] && !@opts[:primary_placeholders]}
        disabled={@opts[:disabled]}
      >{@value}</textarea>
      <.label class="label">
        <span class="fieldset-label">{gettext("Rich text editor (HTML supported)")}</span>
      </.label>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="fieldset-label">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Number Input — bounds (`min`/`max`) are enforced server-side by
  # `validate_type/2`'s `apply_decimal_bounds/2` call, not through
  # browser constraint validation (this renders free text, via
  # `<.decimal_input>`, same as `decimal` below).
  def build_field(%{"type" => "number"} = field, changeset, opts) do
    placeholder = get_effective_placeholder(field, opts)
    value = get_effective_text_value(changeset, field["key"], opts)

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      placeholder: placeholder,
      value: value
    }

    ~H"""
    <div>
      <.label for={@field["key"]}>
        {translated_label(@field, @opts[:lang_code])}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <.decimal_input
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        value={@value}
        placeholder={@placeholder}
        class={["input w-full", @opts[:input_class]]}
        required={@field["required"] && !@opts[:primary_placeholders]}
        disabled={@opts[:disabled]}
      />
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="fieldset-label">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Decimal — same control and bounds enforcement as `number` above.
  def build_field(%{"type" => "decimal"} = field, changeset, opts) do
    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      placeholder: get_effective_placeholder(field, opts),
      value: decimal_input_value(get_effective_text_value(changeset, field["key"], opts))
    }

    ~H"""
    <div>
      <.label for={@field["key"]}>
        {translated_label(@field, @opts[:lang_code])}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <.decimal_input
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        value={@value}
        placeholder={@placeholder}
        class={["input w-full", @opts[:input_class]]}
        required={@field["required"] && !@opts[:primary_placeholders]}
        disabled={@opts[:disabled]}
      />
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="fieldset-label">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Boolean Toggle
  def build_field(%{"type" => "boolean"} = field, changeset, opts) do
    field_value = get_field_value(changeset, field["key"])
    is_checked = field_value in [true, "true", "1", 1]

    assigns = %{field: field, changeset: changeset, opts: opts, is_checked: is_checked}

    ~H"""
    <div>
      <.label>
        {translated_label(@field, @opts[:lang_code])}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <div class="fieldset">
        <label class="label cursor-pointer justify-start gap-4">
          <input
            type="hidden"
            name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
            value="false"
          />
          <input
            type="checkbox"
            name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
            value="true"
            checked={@is_checked}
            class={["toggle toggle-primary", @opts[:input_class]]}
            disabled={@opts[:disabled]}
          />
          <span class="fieldset-legend">
            {if @is_checked, do: gettext("Enabled"), else: gettext("Disabled")}
          </span>
        </label>
      </div>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="fieldset-label">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Date Input
  def build_field(%{"type" => "date"} = field, changeset, opts) do
    assigns = %{field: field, changeset: changeset, opts: opts}

    ~H"""
    <div>
      <.label for={@field["key"]}>
        {translated_label(@field, @opts[:lang_code])}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <input
        type="date"
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        value={get_field_value(@changeset, @field["key"])}
        class={["input w-full", @opts[:input_class]]}
        required={@field["required"]}
        disabled={@opts[:disabled]}
      />
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="fieldset-label">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Select Dropdown
  def build_field(%{"type" => "select"} = field, changeset, opts) do
    current_value = get_field_value(changeset, field["key"])
    allow_other = FieldTypes.allow_other?(field)
    other_value = allow_other && custom_other_value(current_value, field["options"])

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      allow_other: allow_other,
      other_value: other_value
    }

    ~H"""
    <div>
      <.label for={@field["key"]}>
        {translated_label(@field, @opts[:lang_code])}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <label class={["select w-full", @opts[:input_class]]}>
        <select
          name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
          required={@field["required"]}
          disabled={@opts[:disabled]}
        >
          <%= if @field["allow_empty"] || !@field["required"] do %>
            <option value="">{@field["placeholder"] || gettext("Select an option...")}</option>
          <% end %>
          <%= for option <- (@field["options"] || []) do %>
            <option
              value={option}
              selected={get_field_value(@changeset, @field["key"]) == option}
            >
              {translated_option_label(@field, option, @opts[:lang_code])}
            </option>
          <% end %>
          <%= if @allow_other do %>
            <option value={other_sentinel()} selected={!!@other_value}>
              {gettext("Other")}
            </option>
          <% end %>
        </select>
      </label>
      <%= if @allow_other do %>
        <input
          type="text"
          name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}__other]"}
          value={@other_value}
          placeholder={gettext("Enter custom value")}
          class={["input w-full mt-2", @opts[:input_class]]}
          disabled={@opts[:disabled]}
        />
      <% end %>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="fieldset-label">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Radio Buttons
  def build_field(%{"type" => "radio"} = field, changeset, opts) do
    current_value = get_field_value(changeset, field["key"])
    allow_other = FieldTypes.allow_other?(field)
    other_value = allow_other && custom_other_value(current_value, field["options"])

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      allow_other: allow_other,
      other_value: other_value
    }

    ~H"""
    <div>
      <.label>
        {translated_label(@field, @opts[:lang_code])}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <div class="flex flex-col gap-2">
        <%= for option <- @field["options"] || [] do %>
          <label class="flex items-center cursor-pointer">
            <input
              type="radio"
              name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
              value={option}
              class={["radio radio-primary mr-2", @opts[:input_class]]}
              checked={get_field_value(@changeset, @field["key"]) == option}
              required={@field["required"]}
              disabled={@opts[:disabled]}
            />
            <span class="fieldset-legend">{translated_option_label(@field, option, @opts[:lang_code])}</span>
          </label>
        <% end %>
        <%= if @allow_other do %>
          <label class="flex items-center cursor-pointer gap-2">
            <input
              type="radio"
              name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
              value={other_sentinel()}
              class={["radio radio-primary mr-2", @opts[:input_class]]}
              checked={!!@other_value}
              required={@field["required"]}
              disabled={@opts[:disabled]}
            />
            <span class="fieldset-legend">{gettext("Other")}</span>
            <input
              type="text"
              name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}__other]"}
              value={@other_value}
              placeholder={gettext("Enter custom value")}
              class={["input input-sm flex-1", @opts[:input_class]]}
              disabled={@opts[:disabled]}
            />
          </label>
        <% end %>
      </div>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="fieldset-label">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Checkbox Group
  def build_field(%{"type" => "checkbox"} = field, changeset, opts) do
    current_values = get_field_value(changeset, field["key"]) || []
    allow_other = FieldTypes.allow_other?(field)
    other_value = allow_other && checkbox_other_value(current_values, field["options"])

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      allow_other: allow_other,
      other_value: other_value
    }

    ~H"""
    <div>
      <.label>
        {translated_label(@field, @opts[:lang_code])}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <div class="flex flex-col gap-2">
        <%= for option <- @field["options"] || [] do %>
          <label class="flex items-center cursor-pointer">
            <input
              type="checkbox"
              name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}][]"}
              value={option}
              class={["checkbox checkbox-primary mr-2", @opts[:input_class]]}
              checked={option in (get_field_value(@changeset, @field["key"]) || [])}
              disabled={@opts[:disabled]}
            />
            <span class="fieldset-legend">{translated_option_label(@field, option, @opts[:lang_code])}</span>
          </label>
        <% end %>
        <%= if @allow_other do %>
          <label class="flex items-center cursor-pointer gap-2">
            <input
              type="checkbox"
              name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}][]"}
              value={other_sentinel()}
              class={["checkbox checkbox-primary mr-2", @opts[:input_class]]}
              checked={!!@other_value}
              disabled={@opts[:disabled]}
            />
            <span class="fieldset-legend">{gettext("Other")}</span>
            <input
              type="text"
              name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}__other]"}
              value={@other_value}
              placeholder={gettext("Enter custom value")}
              class={["input input-sm flex-1", @opts[:input_class]]}
              disabled={@opts[:disabled]}
            />
          </label>
        <% end %>
      </div>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="fieldset-label">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Image Upload (placeholder - not yet implemented)
  # Media references (image/video) store a storage file uuid picked
  # through a media picker. The value ALWAYS rides a hidden input:
  # validate_data/3 rebuilds every field from form params, so a value
  # that lives only in the changeset is wiped by the next keystroke —
  # before the hidden input, any DataForm save silently dropped stored
  # media. With `opts[:media_picker]` (the admin DataForm) Choose/Clear
  # buttons drive a page-level `MediaSelectorModal` via the
  # `pick_media_field`/`clear_media_field` events; without it the value
  # renders read-only as before.
  def build_field(%{"type" => type} = field, changeset, opts) when type in ["image", "video"] do
    current = get_field_value(changeset, field["key"])
    picker? = opts[:media_picker] && !opts[:disabled]

    assigns = %{
      field: field,
      opts: opts,
      current: current,
      type: type,
      picker?: picker?,
      input_name: "#{changeset.data.__struct__.__schema__(:source)}[data][#{field["key"]}]"
    }

    ~H"""
    <div>
      <.label>
        {translated_label(@field, @opts[:lang_code])}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <input type="hidden" name={@input_name} value={@current} />
      <div class="border border-base-300 rounded-lg p-4 bg-base-200/50 flex items-center gap-3">
        <%= if is_binary(@current) and match?({:ok, _}, Ecto.UUID.cast(@current)) do %>
          <img
            :if={@type == "image"}
            src={PhoenixKit.Modules.Storage.URLSigner.signed_url(@current, "thumbnail")}
            alt={@field["label"]}
            class="w-16 h-16 object-cover rounded"
          />
          <.icon
            :if={@type == "video"}
            name="hero-video-camera"
            class="w-10 h-10 text-base-content/40"
          />
          <div class="text-sm text-base-content/70 min-w-0">
            <p class="font-medium">{gettext("Media file")}</p>
            <p class="text-xs text-base-content/50 truncate">{@current}</p>
          </div>
        <% else %>
          <.icon
            name={if @type == "image", do: "hero-photo", else: "hero-video-camera"}
            class="w-10 h-10 text-base-content/40"
          />
          <p class="text-sm text-base-content/60">
            <%= if @picker? do %>
              {gettext("No media selected.")}
            <% else %>
              {gettext("No media selected — set through the owning app's editor.")}
            <% end %>
          </p>
        <% end %>
        <div :if={@picker?} class="flex gap-2 ml-auto shrink-0">
          <button
            type="button"
            class="btn btn-sm"
            phx-click="pick_media_field"
            phx-value-key={@field["key"]}
            phx-value-type={@type}
          >
            {gettext("Choose…")}
          </button>
          <button
            :if={is_binary(@current) and @current != ""}
            type="button"
            class="btn btn-sm btn-ghost"
            phx-click="clear_media_field"
            phx-value-key={@field["key"]}
          >
            {gettext("Clear")}
          </button>
        </div>
      </div>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="fieldset-label">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # File Upload (admin entity forms - requires LiveView upload configuration)
  def build_field(%{"type" => "file"} = field, changeset, opts) do
    # Get current value from changeset (array of file metadata)
    current_files = get_field_value(changeset, field["key"]) || []

    # Extract upload configuration
    max_entries = field["max_entries"] || 5
    max_file_size_mb = Float.round((field["max_file_size"] || 15_728_640) / 1_048_576, 1)
    accept_list = field["accept"] || [".pdf", ".jpg", ".jpeg", ".png"]

    accept_display =
      Enum.map_join(accept_list, ", ", fn ext ->
        ext |> String.replace_prefix(".", "") |> String.upcase()
      end)

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      current_files: current_files,
      max_entries: max_entries,
      max_file_size_mb: max_file_size_mb,
      accept_display: accept_display
    }

    ~H"""
    <div>
      <.label>
        {translated_label(@field, @opts[:lang_code])}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>

      <%!-- Display current files if any --%>
      <%= if @current_files != [] and is_list(@current_files) do %>
        <div class="mb-3 space-y-2">
          <p class="text-sm font-semibold text-base-content/70">
            {gettext("Current files:")}
          </p>
          <%!-- SECURITY: `is_map(file)` is not defensive noise. `file` fields
          have no submittable input anywhere in this library (this clause is a
          placeholder and nothing here consumes an upload), so every value
          under a `file` key arrives from outside — a crafted admin autosave,
          or the public `/entities/:entity_slug/submit` POST when the field is
          listed in `public_form_fields`. `EntityData.changeset/2` has no
          shape opinion on `file` (it falls to the catch-all clause of
          `dispatch_field_type_validation/4`), so a list of plain strings
          stores fine and then reaches `file["filename"]` here, where the
          Access syntax raises `FunctionClauseError` on a binary — crashing
          the admin editor for that record for good. Skipping non-map entries
          renders the entries that do have the expected metadata shape and
          ignores the rest. --%>
          <%= for file <- @current_files, is_map(file) do %>
            <div class="flex items-center gap-2 p-2 bg-base-200 rounded text-sm">
              <.icon name="hero-document" class="w-4 h-4 text-base-content/60" />
              <span class="flex-1 truncate">{file["filename"] || gettext("Unknown file")}</span>
              <%= if file["size"] do %>
                <span class="text-xs text-base-content/60">
                  {format_bytes(file["size"])}
                </span>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- File upload placeholder for admin forms --%>
      <div class="border-2 border-dashed border-base-300 rounded-lg p-6 text-center bg-base-200/50">
        <.icon name="hero-document-arrow-up" class="w-12 h-12 mx-auto text-base-content/40 mb-3" />
        <p class="text-base-content/60 text-sm mb-2">
          {gettext("File upload in admin forms requires LiveView upload configuration")}
        </p>
        <p class="text-base-content/40 text-xs mb-3">
          {gettext("File uploads work in public forms (contact forms, etc.)")}
        </p>

        <%!-- Show field configuration --%>
        <div class="text-left mt-4 p-3 bg-base-100 rounded text-xs space-y-1">
          <p class="font-semibold text-base-content/70">{gettext("Field Configuration:")}</p>
          <p class="text-base-content/60">
            • {gettext("Accepted types:")} {@accept_display}
          </p>
          <p class="text-base-content/60">
            • {gettext("Max files:")} {@max_entries}
          </p>
          <p class="text-base-content/60">
            • {gettext("Max size:")} {@max_file_size_mb} MB {gettext("per file")}
          </p>
        </div>
      </div>

      <%= if @field["description"] do %>
        <.label class="label">
          <span class="fieldset-label">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Relation Field (placeholder - not yet implemented)
  def build_field(%{"type" => "relation"} = field, changeset, opts) do
    assigns = %{field: field, changeset: changeset, opts: opts}

    ~H"""
    <div>
      <.label>
        {translated_label(@field, @opts[:lang_code])}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <div class="border-2 border-dashed border-base-300 rounded-lg p-6 text-center bg-base-200/50">
        <.icon name="hero-link" class="w-12 h-12 mx-auto text-base-content/40 mb-3" />
        <p class="text-base-content/60 text-sm mb-2">
          {gettext("Entity relations coming soon")}
        </p>
        <p class="text-base-content/40 text-xs">
          {gettext("This feature is not yet available")}
        </p>
      </div>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="fieldset-label">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Section Heading — display-only, not bound to the changeset (no data,
  # no input, never required). Still accepts `opts` (unlike every other
  # arg here) purely to read `opts[:lang_code]` for `translated_label/2`.
  def build_field(%{"type" => "heading"} = field, _changeset, opts) do
    assigns = %{label: translated_label(field, opts[:lang_code])}

    ~H"""
    <h3 class="text-base font-semibold border-b border-base-300 pb-1 mt-6 mb-2">
      {@label}
    </h3>
    """
  end

  # Fallback for unknown field types
  def build_field(field, changeset, opts) do
    assigns = %{field: field, changeset: changeset, opts: opts}

    ~H"""
    <div class="alert alert-warning">
      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
      <span>{gettext("Unknown field type: %{type}", type: @field["type"])}</span>
    </div>
    """
  end

  defp format_bytes(bytes), do: Format.bytes(bytes)

  # The sentinel accessor exists (rather than inlining `@other_sentinel`) so
  # templates can call it directly — `@` inside `~H` reads assigns, not
  # module attributes.
  defp other_sentinel, do: @other_sentinel

  # For single-value fields (radio/select): the stored value counts as a
  # custom "Other" entry when it's present but not one of the fixed options.
  defp custom_other_value(value, _options) when value in [nil, ""], do: nil

  defp custom_other_value(value, options) do
    if value in (options || []), do: nil, else: value
  end

  # For checkbox (multi-value): whatever survives after removing the known
  # options is the free-text "Other" entry. Only one text input exists, so
  # if several unknown values are somehow present, the first one wins.
  defp checkbox_other_value(values, options) do
    case values -- (options || []) do
      [] -> nil
      [extra | _] -> extra
    end
  end

  @doc """
  Validates entity data against field definitions.

  Takes entity field definitions and validates submitted data parameters
  according to the field types, requirements, and constraints.

  ## Parameters

  - `entity` - The entity with field definitions
  - `data_params` - Map of submitted data parameters

  ## Returns

  - `{:ok, validated_data}` - Successfully validated data
  - `{:error, errors}` - Validation errors

  ## Examples

      iex> entity = %Entities{fields_definition: [
      ...>   %{"type" => "text", "key" => "title", "required" => true}
      ...> ]}
      iex> PhoenixKitEntities.FormBuilder.validate_data(entity, %{"title" => "Test"})
      {:ok, %{"title" => "Test"}}

      iex> PhoenixKitEntities.FormBuilder.validate_data(entity, %{})
      {:error, %{"title" => ["is required"]}}
  """
  def validate_data(entity, data_params, lang_code \\ nil)

  def validate_data(entity, data_params, nil) do
    fields_definition = entity.fields_definition || []
    errors = %{}
    validated_data = %{}

    result =
      Enum.reduce(fields_definition, {validated_data, errors}, fn
        # Display-only — no data to validate or store.
        %{"type" => "heading"}, acc ->
          acc

        field, {data_acc, errors_acc} ->
          field_key = field["key"]
          field_value = Map.get(data_params, field_key)

          case validate_field_value(field, field_value) do
            {:ok, validated_value} ->
              {Map.put(data_acc, field_key, validated_value), errors_acc}

            {:error, field_errors} ->
              {data_acc, Map.put(errors_acc, field_key, field_errors)}
          end
      end)

    case result do
      {validated_data, errors} when map_size(errors) == 0 ->
        {:ok, validated_data}

      {_data, errors} ->
        {:error, errors}
    end
  end

  def validate_data(entity, data_params, lang_code) do
    primary = Multilang.primary_language()

    if lang_code == primary do
      # Primary language: full validation (same as default)
      validate_data(entity, data_params, nil)
    else
      # Secondary language: type validation only, no required checks.
      # Empty values are stripped (not stored as overrides).
      validate_secondary_data(entity, data_params)
    end
  end

  defp validate_secondary_data(entity, data_params) do
    fields_definition = entity.fields_definition || []

    result =
      Enum.reduce(fields_definition, {%{}, %{}}, fn
        # Display-only — no data to validate or store.
        %{"type" => "heading"}, acc ->
          acc

        field, {data_acc, errors_acc} ->
          field_key = field["key"]
          field_value = Map.get(data_params, field_key)

          if is_nil(field_value) or field_value == "" do
            {data_acc, errors_acc}
          else
            validate_secondary_field(field_key, field, field_value, data_acc, errors_acc)
          end
      end)

    case result do
      {validated_data, errors} when map_size(errors) == 0 ->
        {:ok, validated_data}

      {_data, errors} ->
        {:error, errors}
    end
  end

  defp validate_secondary_field(field_key, field, value, data_acc, errors_acc) do
    case validate_type(field, value) do
      {:ok, validated_value} ->
        {Map.put(data_acc, field_key, validated_value), errors_acc}

      {:error, field_errors} ->
        {data_acc, Map.put(errors_acc, field_key, field_errors)}
    end
  end

  @doc """
  Resolves `allow_other` sentinel values in submitted params back into free text.

  Radio/select/checkbox fields with `"allow_other" => true` render an extra
  "Other" option whose value is the sentinel `"__other__"`, paired with a
  companion `<key>__other` text input. This function replaces the sentinel
  with the companion field's text (defaulting to `""` if absent) and drops
  every `<key>__other` companion key from the result. A no-op for fields
  without `allow_other`, or for values that aren't the sentinel.

  ## Examples

      iex> field = %{"type" => "radio", "key" => "color", "allow_other" => true}
      iex> PhoenixKitEntities.FormBuilder.merge_other_params(
      ...>   [field],
      ...>   %{"color" => "__other__", "color__other" => "Crimson"}
      ...> )
      %{"color" => "Crimson"}
  """
  def merge_other_params(fields_definition, params) when is_map(params) do
    other_keys =
      for field <- fields_definition,
          FieldTypes.allow_other?(field),
          field["type"] in ["radio", "select", "checkbox"],
          do: field["key"]

    companion_keys = Enum.map(other_keys, &"#{&1}__other")

    params
    |> Enum.reduce(params, &resolve_other_param(&1, &2, other_keys, params))
    |> Map.drop(companion_keys)
  end

  defp resolve_other_param({key, @other_sentinel}, acc, other_keys, params) do
    if key in other_keys,
      do: Map.put(acc, key, Map.get(params, "#{key}__other", "")),
      else: acc
  end

  defp resolve_other_param({key, values}, acc, other_keys, params) when is_list(values) do
    if key in other_keys and @other_sentinel in values do
      text = Map.get(params, "#{key}__other", "")

      resolved =
        values
        |> Enum.map(&if(&1 == @other_sentinel, do: text, else: &1))
        # An "Other" checkbox ticked with no text typed shouldn't leave a
        # blank entry in the stored list.
        |> Enum.reject(&(&1 == ""))

      Map.put(acc, key, resolved)
    else
      acc
    end
  end

  defp resolve_other_param(_pair, acc, _other_keys, _params), do: acc

  @doc """
  Gets the current value of a field from a changeset.

  Helper function to extract field values from changesets or forms for form rendering.
  """
  def get_field_value(%Phoenix.HTML.Form{} = form, field_key) do
    # When passed a form, access the underlying changeset
    # Use Ecto.Changeset.get_field to get the value from changes or fallback to struct
    case Ecto.Changeset.get_field(form.source, :data) do
      nil -> nil
      data when is_map(data) -> Map.get(data, field_key)
      _ -> nil
    end
  end

  def get_field_value(changeset, field_key) do
    # When passed a changeset directly
    case Ecto.Changeset.get_field(changeset, :data) do
      nil -> nil
      data when is_map(data) -> Map.get(data, field_key)
      _ -> nil
    end
  end

  @doc """
  Casts ONE raw (form-submitted) value against its field definition —
  the per-field core of `validate_data/2`, public for hosts that own
  their own save events (inline row editors embedding
  `PhoenixKitEntities.Components.FieldInput`).

  Returns `{:ok, coerced}` (numbers parsed, booleans normalized, choice
  membership enforced, media references uuid-checked…) or
  `{:error, messages}`.

  Normalizations for bare-control submissions: `""` casts to `nil`
  (blur-clearing an input clears the stored key — required fields still
  error), and a `checkbox` group's hidden-input `""`/`nil` casts to
  `[]`.
  """
  @spec cast_field(map(), term()) :: {:ok, term()} | {:error, [String.t()]}
  def cast_field(field, raw_value) do
    value =
      case {field["type"], raw_value} do
        {"checkbox", raw} -> normalize_checkbox(raw)
        {_type, ""} -> nil
        {_type, other} -> other
      end

    validate_field_value(field, value)
  end

  # Private Functions

  defp validate_field_value(field, value) do
    with {:ok, value} <- validate_required(field, value) do
      validate_type(field, value)
    end
  end

  # A checkbox group submitted through FieldInput's hidden fallback
  # arrives as a list that may carry the hidden "" entry — strip it
  # before membership validation.
  defp normalize_checkbox(value), do: value |> List.wrap() |> Enum.reject(&(&1 == ""))

  defp validate_required(%{"required" => true}, value) when value in [nil, "", []] do
    {:error, [gettext("is required")]}
  end

  defp validate_required(_field, value), do: {:ok, value}

  defp validate_type(%{"type" => "email"}, value) when is_binary(value) and value != "" do
    if String.contains?(value, "@") do
      {:ok, value}
    else
      {:error, [gettext("must be a valid email address")]}
    end
  end

  defp validate_type(%{"type" => "url"}, value) when is_binary(value) and value != "" do
    normalized_value =
      if String.starts_with?(value, ["http://", "https://"]) do
        value
      else
        "https://#{value}"
      end

    {:ok, normalized_value}
  end

  defp validate_type(%{"type" => "number"} = field, value)
       when is_binary(value) and value != "" do
    case Number.parse_decimal(value) do
      {:ok, decimal} -> bound_number(field, decimal)
      {:error, _reason} -> {:error, [gettext("must be a valid number")]}
    end
  end

  # A value already cast to a number (a re-validate of an unchanged form, or
  # a caller passing typed data directly) previously fell through to the
  # catch-all clause at the bottom of this function and skipped
  # `apply_decimal_bounds/2` entirely — the ONLY branch of this type that
  # enforces `min`/`max`. Route it through the same bounds check as the
  # binary branch above.
  defp validate_type(%{"type" => "number"} = field, %Decimal{} = value),
    do: bound_number(field, value)

  defp validate_type(%{"type" => "number"} = field, value) when is_integer(value),
    do: bound_number(field, Decimal.new(value))

  defp validate_type(%{"type" => "number"} = field, value) when is_float(value),
    do: bound_number(field, value |> Float.to_string() |> Decimal.new())

  # Exact numeric. `Number.parse_decimal/2` is used rather than
  # `Float.parse/1` precisely so the value never round-trips through a
  # float — that is the whole reason this type exists. A `%Decimal{}`
  # arriving already cast (a re-validate of an unchanged form) passes
  # straight through.
  defp validate_type(%{"type" => "decimal"} = field, %Decimal{} = value),
    do: apply_decimal_bounds(field, value)

  defp validate_type(%{"type" => "decimal"} = field, value)
       when is_binary(value) and value != "" do
    # Comma decimal separators are the norm in et/ru locales;
    # `Number.parse_decimal/2` accepts either — but it also normalizes
    # away trailing zeros ("5.1000" -> 5.1), which is wrong here: this
    # type's whole reason to exist is to preserve exactly the precision
    # a person typed (5.10 is a different price from 5.1 on an invoice).
    # Restore it from the typed text once the value itself is confirmed
    # valid.
    case Number.parse_decimal(value) do
      {:ok, decimal} -> apply_decimal_bounds(field, restore_typed_scale(decimal, value))
      {:error, _reason} -> {:error, [gettext("must be a valid number")]}
    end
  end

  defp validate_type(%{"type" => "decimal"} = field, value) when is_integer(value),
    do: apply_decimal_bounds(field, Decimal.new(value))

  # A float can only arrive from data written before this type existed —
  # accept it rather than failing the form, via the string form so the
  # binary representation is not carried into the Decimal.
  defp validate_type(%{"type" => "decimal"} = field, value) when is_float(value),
    do: apply_decimal_bounds(field, value |> Float.to_string() |> Decimal.new())

  defp validate_type(%{"type" => "boolean"}, value) do
    cond do
      value in [true, "true", "1", 1] -> {:ok, true}
      value in [false, "false", "0", 0, nil, ""] -> {:ok, false}
      true -> {:error, [gettext("must be true or false")]}
    end
  end

  defp validate_type(%{"type" => "select", "options" => options} = field, value)
       when is_list(options) do
    cond do
      value in [nil, ""] -> {:ok, nil}
      value in options -> {:ok, value}
      FieldTypes.allow_other?(field) and is_binary(value) -> {:ok, value}
      true -> {:error, [gettext("must be one of: %{options}", options: Enum.join(options, ", "))]}
    end
  end

  defp validate_type(%{"type" => "radio", "options" => options} = field, value)
       when is_list(options) do
    cond do
      value in [nil, ""] -> {:ok, nil}
      value in options -> {:ok, value}
      FieldTypes.allow_other?(field) and is_binary(value) -> {:ok, value}
      true -> {:error, [gettext("must be one of: %{options}", options: Enum.join(options, ", "))]}
    end
  end

  # `allow_other`'s branch requires every out-of-options entry to be a
  # binary — same shape rule as the `select`/`radio` clauses above (both
  # already gate on `is_binary(value)`). `allow_other` means "one
  # free-text custom entry", not "any term"; without this, a crafted
  # list-of-maps value sailed straight through this best-effort layer,
  # relying entirely on `EntityData.changeset/2`'s
  # `validate_checkbox_field/3` (the hard-blocking final gate) to catch
  # it — kept in sync with that changeset-level fix for consistency
  # between the two validators, not because this layer is itself
  # security-load-bearing (see this module's moduledoc: it's best-effort,
  # never a hard gate).
  defp validate_type(%{"type" => "checkbox", "options" => options} = field, values)
       when is_list(options) and is_list(values) do
    invalid_values = values -- options

    cond do
      Enum.empty?(invalid_values) ->
        {:ok, values}

      FieldTypes.allow_other?(field) and Enum.all?(invalid_values, &is_binary/1) ->
        {:ok, values}

      true ->
        {:error,
         [
           gettext("contains invalid options: %{invalid}",
             invalid: Enum.map_join(invalid_values, ", ", &stringify_invalid_option/1)
           )
         ]}
    end
  end

  # Media references: the stored value is a storage file uuid (or
  # empty). Anything else would crash every renderer that resolves the
  # uuid to a thumbnail/URL.
  defp validate_type(%{"type" => type}, value)
       when type in ["image", "video"] and is_binary(value) and value != "" do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> {:ok, value}
      :error -> {:error, [gettext("must be a media file reference")]}
    end
  end

  defp validate_type(%{"type" => type}, value)
       when type in ["image", "video"] and not is_nil(value) and value != "" do
    {:error, [gettext("must be a media file reference")]}
  end

  defp validate_type(_field, value), do: {:ok, value}

  # The number of fractional digits typed, mirroring `Number.parse_decimal/2`'s
  # own documented separator rule (its `@doc`) instead of a simpler
  # "last separator wins" regex: a repeated separator on its own
  # ("1,234,567", the European "1.234.567") is thousands grouping, not a
  # fraction, and must not be misread as one — that previously padded
  # fabricated trailing zeros onto a whole number. `Decimal.round/2` back
  # to the resolved count only pads/trims zeros; it never changes the
  # value, since `parse_decimal/2`'s normalizing never adds significant
  # digits.
  #
  # This duplicates that rule (and the `last_index/2` helper below) by
  # hand because core keeps its own copy private — nothing to call
  # instead. Follow-up: once core exports the resolution rule, replace
  # this copy so the two can't silently drift.
  defp restore_typed_scale(decimal, raw) do
    text = raw |> String.trim() |> String.replace(~r/[ \x{00A0}\x{2009}\x{202F}]/u, "")
    dots = text |> String.graphemes() |> Enum.count(&(&1 == "."))
    commas = text |> String.graphemes() |> Enum.count(&(&1 == ","))

    fraction_digits =
      cond do
        # Both present: the last one typed is the decimal point (same
        # rule `Number.parse_decimal/2` uses), the other is grouping.
        dots > 0 and commas > 0 ->
          point = if last_index(text, ".") > last_index(text, ","), do: ".", else: ","
          text |> String.split(point) |> List.last() |> String.length()

        # One kind repeated with nothing else present is grouping —
        # there is no fraction to restore.
        commas > 1 or dots > 1 ->
          0

        true ->
          case Regex.run(~r/[.,](\d+)\z/, text) do
            [_, fraction] -> String.length(fraction)
            nil -> 0
          end
      end

    Decimal.round(decimal, fraction_digits)
  end

  defp last_index(text, char) do
    case :binary.matches(text, char) do
      [] -> -1
      matches -> matches |> List.last() |> elem(0)
    end
  end

  # Shared by the `number` type's `validate_type/2` clauses above:
  # bounds-check then hand back a float, matching this type's documented
  # "integer or decimal via float" contract (unlike `decimal`, which stays
  # a `Decimal` end to end).
  defp bound_number(field, %Decimal{} = decimal) do
    case apply_decimal_bounds(field, decimal) do
      {:ok, bounded} -> {:ok, Decimal.to_float(bounded)}
      {:error, _reasons} = error -> error
    end
  end

  # Shared by both numeric types' `validate_type/2` clauses. `number`
  # used to lean on the browser's native `<input min max>` for this and
  # enforced nothing server-side; now that both types render through
  # `<.decimal_input>` (free text, no browser constraint validation),
  # this is the only enforcement either gets.
  defp apply_decimal_bounds(field, %Decimal{} = value) do
    cond do
      below?(value, field["min"]) ->
        {:error, [gettext("must be at least %{min}", min: field["min"])]}

      above?(value, field["max"]) ->
        {:error, [gettext("must be at most %{max}", max: field["max"])]}

      true ->
        {:ok, value}
    end
  end

  defp below?(value, min), do: compare_bound(value, min) == :lt
  defp above?(value, max), do: compare_bound(value, max) == :gt

  # An unparseable bound is IGNORED rather than raised on. `min`/`max` come
  # from a field definition, which an admin can edit; a typo there must not
  # turn every save of that field into a crash. A `"NaN"` bound parses,
  # but `Decimal.compare/2` raises on it, so it is ignored too.
  defp compare_bound(_value, nil), do: :eq

  defp compare_bound(value, bound) do
    case to_decimal(bound) do
      %Decimal{} = limit -> if Decimal.nan?(limit), do: :eq, else: Decimal.compare(value, limit)
      nil -> :eq
    end
  end

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp to_decimal(value) when is_binary(value) do
    case value |> String.trim() |> Decimal.parse() do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp to_decimal(_value), do: nil

  defp decimal_input_value(value), do: FieldTypes.decimal_input_value(value)

  # `invalid_values` (used by the checkbox clause above) can now
  # legitimately contain a non-binary term (a crafted map, for one — see
  # the `allow_other` shape guard there), and `Enum.join/2` calls
  # `to_string/1` on every element via `String.Chars`, which has no
  # implementation for a bare map — this crashed building the ERROR
  # MESSAGE ITSELF (a raised `Protocol.UndefinedError`, not the graceful
  # `{:error, _}` this function returns everywhere else), independent of
  # `allow_other`. `to_string/1` for a binary (the normal case),
  # `inspect/1` for anything else (always succeeds, never raises).
  defp stringify_invalid_option(value) when is_binary(value), do: value
  defp stringify_invalid_option(value), do: inspect(value)
end
