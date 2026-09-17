defmodule PhoenixKitEntities.FieldTypes do
  @moduledoc """
  Field type definitions and utilities for the Entities system.

  This module defines all supported field types for entity definitions,
  including their properties, validation rules, and rendering information.

  ## Supported Field Types

  ### Basic Text Types
  - **text**: Single-line text input
  - **textarea**: Multi-line text area
  - **email**: Email address with validation
  - **url**: URL with validation
  - **rich_text**: Rich HTML editor (TinyMCE/CKEditor-like)
  - **heading**: Display-only section heading (no data), category `:basic`

  ### Numeric Types
  - **number**: Numeric input (integer or decimal)

  ### Boolean Types
  - **boolean**: True/false toggle or checkbox

  ### Date/Time Types
  - **date**: Date picker (YYYY-MM-DD format)

  ### Choice Types
  - **select**: Dropdown selection (single choice)
  - **radio**: Radio button group (single choice)
  - **checkbox**: Checkbox group (multiple choices)

  ## Usage Examples

      # Get all field types
      field_types = PhoenixKitEntities.FieldTypes.all()

      # Get field type info
      text_info = PhoenixKitEntities.FieldTypes.get_type("text")

      # Get field types by category
      basic_types = PhoenixKitEntities.FieldTypes.by_category(:basic)

      # Check if field type requires options
      PhoenixKitEntities.FieldTypes.requires_options?("select") # => true
  """

  use Gettext, backend: PhoenixKitEntities.Gettext

  alias PhoenixKitEntities.FieldType

  @type field_type :: String.t()
  @type field_category ::
          :basic | :numeric | :boolean | :datetime | :choice | :advanced

  @field_types %{
    "text" => %{
      name: "text",
      label: "Text",
      description: "Single-line text input",
      category: :basic,
      icon: "hero-pencil",
      requires_options: false,
      default_props: %{
        "placeholder" => "",
        "max_length" => 255
      }
    },
    "textarea" => %{
      name: "textarea",
      label: "Text Area",
      description: "Multi-line text input",
      category: :basic,
      icon: "hero-document-text",
      requires_options: false,
      default_props: %{
        "placeholder" => "",
        "rows" => 4,
        "max_length" => 5000
      }
    },
    "email" => %{
      name: "email",
      label: "Email",
      description: "Email address with validation",
      category: :basic,
      icon: "hero-envelope",
      requires_options: false,
      default_props: %{
        "placeholder" => "user@example.com"
      }
    },
    "url" => %{
      name: "url",
      label: "URL",
      description: "Website URL with validation",
      category: :basic,
      icon: "hero-link",
      requires_options: false,
      default_props: %{
        "placeholder" => "https://example.com"
      }
    },
    "rich_text" => %{
      name: "rich_text",
      label: "Rich Text Editor",
      description: "WYSIWYG HTML editor",
      category: :basic,
      icon: "hero-document-text",
      requires_options: false,
      default_props: %{
        "toolbar" => "basic"
      }
    },
    "number" => %{
      name: "number",
      label: "Number",
      description: "Numeric input (integer or decimal)",
      category: :numeric,
      icon: "hero-hashtag",
      requires_options: false,
      default_props: %{
        "min" => nil,
        "max" => nil,
        "step" => 1
      }
    },
    # Exact numeric. `number` casts through `Number.parse_decimal/2` but
    # still hands back a float, which is fine for counts and measurements
    # but silently rounds money — 0.1 + 0.2 is the classic. This type
    # carries the value as a Decimal end to end: cast returns %Decimal{},
    # storage is the canonical string form (JSON has no decimal, and a
    # float round-trip would undo the point), and reads hand back a
    # Decimal again.
    "decimal" => %{
      name: "decimal",
      label: "Decimal",
      description: "Exact decimal number — money, rates, anything that must not round",
      category: :numeric,
      icon: "hero-banknotes",
      requires_options: false,
      default_props: %{
        "min" => nil,
        "max" => nil,
        # 4 places matches phoenix_kit_cat_item_supplier_info.unit_cost
        # NUMERIC(14,4), the first consumer.
        "scale" => 4,
        # Stepping override for the number input: nil derives it from
        # `scale`, "any" turns stepping off (whole-unit arrows, every
        # place still typeable). A step coarser than `scale` is refused
        # — the browser validates against it and would block the submit
        # — see `decimal_step/1`.
        "step" => nil
      }
    },
    "boolean" => %{
      name: "boolean",
      label: "Boolean",
      description: "True/false toggle",
      category: :boolean,
      icon: "hero-check-circle",
      requires_options: false,
      default_props: %{
        "default" => false
      }
    },
    "date" => %{
      name: "date",
      label: "Date",
      description: "Date picker",
      category: :datetime,
      icon: "hero-calendar",
      requires_options: false,
      default_props: %{
        "format" => "Y-m-d"
      }
    },
    "select" => %{
      name: "select",
      label: "Select Dropdown",
      description: "Dropdown selection (single choice)",
      category: :choice,
      icon: "hero-chevron-down",
      requires_options: true,
      default_props: %{
        "placeholder" => "Select an option...",
        "allow_empty" => true
      }
    },
    "radio" => %{
      name: "radio",
      label: "Radio Buttons",
      description: "Radio button group (single choice)",
      category: :choice,
      icon: "hero-check-circle",
      requires_options: true,
      default_props: %{}
    },
    "checkbox" => %{
      name: "checkbox",
      label: "Checkboxes",
      description: "Checkbox group (multiple choices)",
      category: :choice,
      icon: "hero-check",
      requires_options: true,
      default_props: %{
        "allow_multiple" => true
      }
    },
    "file" => %{
      name: "file",
      label: "File Upload",
      description: "File upload field with configurable constraints",
      category: :advanced,
      icon: "hero-document-arrow-up",
      requires_options: false,
      default_props: %{
        "max_entries" => 5,
        "max_file_size" => 15_728_640,
        "accept" => [".pdf", ".jpg", ".jpeg", ".png"]
      }
    },
    # Media references (picker + uuid model): the VALUE is a storage
    # file uuid chosen through the host's media picker (e.g. core's
    # MediaSelectorModal) — never a raw upload owned by this module.
    # Raw uploads here would grow a second file store next to core
    # Storage (no dedup/trash/variants/signed URLs); a reference keeps
    # Storage canonical. Rendered inline by
    # `PhoenixKitEntities.Components.FieldInput`; the admin DataForm
    # shows the stored value read-only until it gains picker wiring.
    "image" => %{
      name: "image",
      label: "Image",
      description: "One image from the media library (stores a file reference)",
      category: :advanced,
      icon: "hero-photo",
      requires_options: false,
      default_props: %{}
    },
    "video" => %{
      name: "video",
      label: "Video",
      description: "One video from the media library (stores a file reference)",
      category: :advanced,
      icon: "hero-video-camera",
      requires_options: false,
      default_props: %{}
    },
    "heading" => %{
      name: "heading",
      label: "Section Heading",
      description: "Display-only section heading (no data)",
      category: :basic,
      icon: "hero-bars-3-bottom-left",
      requires_options: false,
      default_props: %{}
    }
  }

  @doc """
  Returns all field types as a map of `%FieldType{}` structs.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.all()
      %{"text" => %FieldType{name: "text", ...}, ...}
  """
  @spec all() :: %{String.t() => FieldType.t()}
  def all do
    Map.new(@field_types, fn {key, map} -> {key, FieldType.from_map(map)} end)
  end

  @doc """
  Returns a list of all field type names.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.list_types()
      ["text", "textarea", "number", ...]
  """
  def list_types do
    Map.keys(@field_types)
  end

  @doc """
  Gets information about a specific field type.

  Returns nil if the type doesn't exist.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.get_type("text")
      %FieldType{name: "text", label: "Text", ...}

      iex> PhoenixKitEntities.FieldTypes.get_type("invalid")
      nil
  """
  @spec get_type(String.t()) :: FieldType.t() | nil
  def get_type(type_name) when is_binary(type_name) do
    case Map.get(@field_types, type_name) do
      nil -> nil
      map -> FieldType.from_map(map)
    end
  end

  @doc """
  Checks if a field type exists.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.valid_type?("text")
      true

      iex> PhoenixKitEntities.FieldTypes.valid_type?("invalid")
      false
  """
  def valid_type?(type_name) when is_binary(type_name) do
    Map.has_key?(@field_types, type_name)
  end

  @doc """
  Returns field types grouped by category.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.by_category(:basic)
      [%FieldType{name: "text", ...}, %FieldType{name: "textarea", ...}, ...]
  """
  @spec by_category(field_category()) :: [FieldType.t()]
  def by_category(category) when is_atom(category) do
    @field_types
    |> Map.values()
    |> Enum.filter(fn type -> type.category == category end)
    |> Enum.map(&FieldType.from_map/1)
  end

  @doc """
  Returns all categories with their field types.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.categories()
      %{
        basic: [%{name: "text", ...}, ...],
        numeric: [%{name: "number", ...}],
        ...
      }
  """
  def categories do
    @field_types
    |> Map.values()
    |> Enum.map(&FieldType.from_map/1)
    |> Enum.group_by(& &1.category)
  end

  @doc """
  Returns a list of category names with labels.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.category_list()
      [
        {:basic, "Basic"},
        {:numeric, "Numeric"},
        ...
      ]
  """
  def category_list do
    # Each label uses a literal `gettext(...)` call so `mix gettext.extract`
    # picks them up. A `gettext(label)` over a variable wouldn't be
    # extracted (extractor only sees literals), and the labels would
    # never be translated.
    [
      {:basic, gettext("Basic")},
      {:numeric, gettext("Numeric")},
      {:boolean, gettext("Boolean")},
      {:datetime, gettext("Date & Time")},
      {:choice, gettext("Choice")},
      {:advanced, gettext("Advanced")}
    ]
  end

  @doc """
  Translated short description for a field type.

  Each clause is a literal `gettext(...)` call so `mix gettext.extract` picks
  the strings up; calling `gettext(type.description)` over the raw map value
  would feed a variable into the extractor and the descriptions would never
  be translated.
  """
  @spec description_for(String.t()) :: String.t()
  def description_for("text"), do: gettext("Single-line text input")
  def description_for("textarea"), do: gettext("Multi-line text input")
  def description_for("email"), do: gettext("Email address with validation")
  def description_for("url"), do: gettext("Website URL with validation")
  def description_for("rich_text"), do: gettext("WYSIWYG HTML editor")
  def description_for("number"), do: gettext("Numeric input (integer or decimal)")
  def description_for("boolean"), do: gettext("True/false toggle")
  def description_for("date"), do: gettext("Date picker")
  def description_for("select"), do: gettext("Dropdown selection (single choice)")
  def description_for("radio"), do: gettext("Radio button group (single choice)")
  def description_for("checkbox"), do: gettext("Checkbox group (multiple choices)")

  def description_for("file"),
    do: gettext("File upload field with configurable constraints")

  def description_for("image"),
    do: gettext("One image from the media library (stores a file reference)")

  def description_for("video"),
    do: gettext("One video from the media library (stores a file reference)")

  def description_for("heading"),
    do: gettext("Display-only section heading (no data)")

  def description_for(type_name) when is_binary(type_name) do
    case Map.get(@field_types, type_name) do
      nil -> ""
      map -> Map.get(map, :description, "")
    end
  end

  @doc """
  Translated display label for a field type.

  Same reasoning as `description_for/1`: each clause is a literal
  `gettext(...)` call so `mix gettext.extract` picks the strings up —
  calling `gettext(type.label)` over the raw `@field_types` map value
  would feed a variable into the extractor and the labels would never be
  translated.
  """
  @spec label_for(String.t()) :: String.t()
  def label_for("text"), do: gettext("Text")
  def label_for("textarea"), do: gettext("Text Area")
  def label_for("email"), do: gettext("Email")
  def label_for("url"), do: gettext("URL")
  def label_for("rich_text"), do: gettext("Rich Text Editor")
  def label_for("number"), do: gettext("Number")
  def label_for("boolean"), do: gettext("Boolean")
  def label_for("date"), do: gettext("Date")
  def label_for("select"), do: gettext("Select Dropdown")
  def label_for("radio"), do: gettext("Radio Buttons")
  def label_for("checkbox"), do: gettext("Checkboxes")
  def label_for("file"), do: gettext("File Upload")
  def label_for("image"), do: gettext("Image")
  def label_for("video"), do: gettext("Video")
  def label_for("heading"), do: gettext("Section Heading")

  def label_for(type_name) when is_binary(type_name) do
    case Map.get(@field_types, type_name) do
      nil -> type_name
      map -> Map.get(map, :label, type_name)
    end
  end

  @doc """
  Checks if a field type requires options to be defined.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.requires_options?("select")
      true

      iex> PhoenixKitEntities.FieldTypes.requires_options?("text")
      false
  """
  def requires_options?(type_name) when is_binary(type_name) do
    case get_type(type_name) do
      nil -> false
      type_info -> Map.get(type_info, :requires_options, false)
    end
  end

  @doc """
  Checks whether a field definition has the `allow_other` ("Muu" custom
  option) flag set — tolerant of both the boolean `true` and the string
  `"true"`.

  Field definition flags in this codebase are submitted from HTML forms
  (where checkbox values arrive as strings) and persisted as-is into the
  `fields_definition` JSONB column, so callers must never compare against
  the literal boolean `true` — that only matches definitions built by hand
  in Elixir, not ones created through the admin field editor.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.allow_other?(%{"allow_other" => true})
      true

      iex> PhoenixKitEntities.FieldTypes.allow_other?(%{"allow_other" => "true"})
      true

      iex> PhoenixKitEntities.FieldTypes.allow_other?(%{})
      false
  """
  @spec allow_other?(map()) :: boolean()
  def allow_other?(field) when is_map(field) do
    field["allow_other"] in [true, "true"]
  end

  @doc """
  Gets the default properties for a field type.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.default_props("text")
      %{"placeholder" => "", "max_length" => 255}
  """
  def default_props(type_name) when is_binary(type_name) do
    case get_type(type_name) do
      nil -> %{}
      type_info -> Map.get(type_info, :default_props, %{})
    end
  end

  @doc """
  Returns field types suitable for a field picker UI.

  Formats the data for use in select dropdowns or type choosers. Grouped by
  category in `category_list/0` order (Basic, Numeric, Boolean, Date & Time,
  Choice, Advanced) — sorting by the translated category *label* instead
  would reorder the picker per-locale (en groups "Date & Time" before
  "Choice"; et's "Kuupäev ja aeg" sorts after "Valik").

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.for_picker()
      [
        %{value: "text", label: "Text", category: "Basic", icon: "hero-pencil"},
        ...
        %{value: "file", label: "File Upload", category: "Advanced", icon: "hero-document-arrow-up"}
      ]
  """
  def for_picker do
    category_labels = Map.new(category_list())

    category_order =
      category_list()
      |> Enum.with_index()
      |> Map.new(fn {{category, _label}, index} -> {category, index} end)

    @field_types
    |> Map.values()
    |> Enum.sort_by(&Map.get(category_order, &1.category, map_size(category_order)))
    |> Enum.map(fn type ->
      %{
        value: type.name,
        label: label_for(type.name),
        description: description_for(type.name),
        category: Map.get(category_labels, type.category, gettext("Other")),
        icon: type.icon,
        requires_options: type.requires_options
      }
    end)
  end

  @doc """
  Validates a field definition map.

  Checks that the field has all required properties and valid values.

  ## Examples

      iex> field = %{"type" => "text", "key" => "title", "label" => "Title"}
      iex> PhoenixKitEntities.FieldTypes.validate_field(field)
      {:ok, field}

      iex> invalid_field = %{"type" => "invalid", "key" => "test"}
      iex> PhoenixKitEntities.FieldTypes.validate_field(invalid_field)
      {:error, {:invalid_field_type, "invalid"}}

  Error tuples flow through `PhoenixKitEntities.Errors.message/1` for
  user-facing strings.
  """
  def validate_field(field) when is_map(field) do
    with {:ok, field} <- validate_required_keys(field),
         {:ok, field} <- validate_type(field) do
      validate_options(field)
    end
  end

  defp validate_required_keys(field) do
    required = ["type", "key", "label"]
    missing = required -- Map.keys(field)

    if Enum.empty?(missing) do
      {:ok, field}
    else
      {:error, {:missing_required_keys, missing}}
    end
  end

  defp validate_type(field) do
    if valid_type?(field["type"]) do
      {:ok, field}
    else
      {:error, {:invalid_field_type, to_string(field["type"])}}
    end
  end

  defp validate_options(field) do
    if requires_options?(field["type"]) do
      options = Map.get(field, "options", [])

      if is_list(options) && not Enum.empty?(options) do
        {:ok, field}
      else
        {:error, {:requires_options, to_string(field["type"])}}
      end
    else
      {:ok, field}
    end
  end

  @doc """
  Creates a new field definition with default values.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.new_field("text", "my_field", "My Field")
      %{
        "type" => "text",
        "key" => "my_field",
        "label" => "My Field",
        "required" => false,
        "default" => "",
        "validation" => %{},
        "placeholder" => "",
        "max_length" => 255
      }

      # With options for choice fields
      iex> PhoenixKitEntities.FieldTypes.new_field("select", "category", "Category", options: ["Tech", "Business"])
      %{
        "type" => "select",
        "key" => "category",
        "label" => "Category",
        "required" => false,
        "options" => ["Tech", "Business"],
        ...
      }

      # With required flag
      iex> PhoenixKitEntities.FieldTypes.new_field("text", "name", "Name", required: true)
      %{"type" => "text", "key" => "name", "label" => "Name", "required" => true, ...}
  """
  def new_field(type, key, label, opts \\ [])

  def new_field(type, key, label, opts)
      when is_binary(type) and is_binary(key) and is_binary(label) do
    options = Keyword.get(opts, :options, [])
    required = Keyword.get(opts, :required, false)
    default = Keyword.get(opts, :default, nil)

    base_field = %{
      "type" => type,
      "key" => key,
      "label" => label,
      "required" => required,
      "default" => default,
      "validation" => %{}
    }

    # Add options for choice fields
    base_field =
      if requires_options?(type) or options != [] do
        Map.put(base_field, "options", options)
      else
        base_field
      end

    # Merge with type-specific default props
    props = default_props(type)
    Map.merge(base_field, props)
  end

  @doc """
  Helper to create a select field with options.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.select_field("category", "Category", ["Tech", "Business", "Other"])
      %{"type" => "select", "key" => "category", "label" => "Category", "options" => ["Tech", "Business", "Other"], ...}

      iex> PhoenixKitEntities.FieldTypes.select_field("status", "Status", ["Active", "Inactive"], required: true)
      %{"type" => "select", "key" => "status", "label" => "Status", "options" => ["Active", "Inactive"], "required" => true, ...}
  """
  def select_field(key, label, options, opts \\ []) when is_list(options) do
    new_field("select", key, label, Keyword.put(opts, :options, options))
  end

  @doc """
  Helper to create a radio button field with options.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.radio_field("priority", "Priority", ["Low", "Medium", "High"])
      %{"type" => "radio", "key" => "priority", "label" => "Priority", "options" => ["Low", "Medium", "High"], ...}
  """
  def radio_field(key, label, options, opts \\ []) when is_list(options) do
    new_field("radio", key, label, Keyword.put(opts, :options, options))
  end

  @doc """
  Helper to create a checkbox field with options.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.checkbox_field("tags", "Tags", ["Featured", "Popular", "New"])
      %{"type" => "checkbox", "key" => "tags", "label" => "Tags", "options" => ["Featured", "Popular", "New"], ...}
  """
  def checkbox_field(key, label, options, opts \\ []) when is_list(options) do
    new_field("checkbox", key, label, Keyword.put(opts, :options, options))
  end

  @doc """
  Helper to create a text field.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.text_field("name", "Full Name", required: true)
      %{"type" => "text", "key" => "name", "label" => "Full Name", "required" => true, ...}
  """
  def text_field(key, label, opts \\ []) do
    new_field("text", key, label, opts)
  end

  @doc """
  Helper to create a textarea field.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.textarea_field("bio", "Biography")
      %{"type" => "textarea", "key" => "bio", "label" => "Biography", ...}
  """
  def textarea_field(key, label, opts \\ []) do
    new_field("textarea", key, label, opts)
  end

  @doc """
  Helper to create an email field.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.email_field("email", "Email Address", required: true)
      %{"type" => "email", "key" => "email", "label" => "Email Address", "required" => true, ...}
  """
  def email_field(key, label, opts \\ []) do
    new_field("email", key, label, opts)
  end

  @doc """
  Helper to create a number field.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.number_field("age", "Age")
      %{"type" => "number", "key" => "age", "label" => "Age", ...}
  """
  def number_field(key, label, opts \\ []) do
    new_field("number", key, label, opts)
  end

  @doc """
  Helper to create a decimal field — exact numeric, for money and
  anything else that must not round.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.decimal_field("unit_cost", "Unit cost")
      %{"type" => "decimal", "key" => "unit_cost", "label" => "Unit cost", ...}
  """
  def decimal_field(key, label, opts \\ []) do
    new_field("decimal", key, label, opts)
  end

  @doc """
  The `step` for a decimal field's numeric input, derived from its
  declared `scale`. Without this the browser rejects the extra decimal
  places the type exists to preserve, because `<input type="number">`
  defaults to `step="1"`.

  A field may override it with an explicit `"step"` prop, but `step` is
  not only the spinner's granularity — the browser validates against it,
  and a `phx-submit` form never reaches LiveView while an input is
  step-mismatched (the submit event fires only after native constraint
  validation passes). So an override is honoured only when it still
  admits every value `scale` promises to keep:

    * `"any"` — no stepping at all, which is the cure for a 4-place
      field whose arrows crawl 0.0001 at a time: the arrows then walk by
      1 and typed entry keeps all four places.
    * a step at least as fine as the scale, i.e. one that divides
      `10^-scale` (`"0.0001"`, `"0.00005"` on a 4-place field).

  A coarser step — `"0.01"` on a 4-place field — would have the browser
  refuse `12.3456` on submit, reintroducing exactly the bug this
  function exists to prevent, so it falls back to the scale-derived
  step. So does anything unparseable, zero or negative. With no declared
  `scale` there is no promise to keep and the explicit step stands.
  """
  @spec decimal_step(map()) :: String.t()
  def decimal_step(field) do
    scale = field["scale"]

    case field["step"] do
      "any" -> "any"
      step when is_binary(step) or is_number(step) -> explicit_step(step, scale)
      _ -> scale_step(scale)
    end
  end

  defp scale_step(scale) when is_integer(scale) and scale > 0,
    do: "0." <> String.duplicate("0", scale - 1) <> "1"

  defp scale_step(_scale), do: "any"

  # Rendered back through Decimal rather than `to_string/1` for the same
  # reason `decimal_input_value/1` is: a small float stringifies as
  # "1.0e-7".
  defp explicit_step(step, scale) do
    with {%Decimal{} = value, ""} <- Decimal.parse(to_string(step)),
         true <- Decimal.positive?(value) and not Decimal.inf?(value),
         true <- admits_scale?(value, scale) do
      Decimal.to_string(value, :normal)
    else
      _ -> scale_step(scale)
    end
  end

  # Every value `scale` allows is a multiple of 10^-scale, so a step
  # admits them all exactly when it divides that unit.
  defp admits_scale?(step, scale) when is_integer(scale) and scale > 0 do
    unit = Decimal.new(1, 1, -scale)
    Decimal.equal?(Decimal.rem(unit, step), 0)
  end

  defp admits_scale?(_step, _scale), do: true

  @doc """
  Renders a stored decimal for an input's `value`. Values arrive as a
  `%Decimal{}` (freshly cast) or the canonical string (round-tripped
  through JSONB); both must render without exponent notation, which an
  `<input type="number">` will not accept.
  """
  @spec decimal_input_value(term()) :: String.t() | nil
  def decimal_input_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  def decimal_input_value(value) when is_binary(value), do: value
  # Via Decimal, not `to_string/1`: a small float stringifies as "1.0e-7",
  # which an `<input type="number">` refuses. Floats only reach here from data
  # written before this type existed.
  def decimal_input_value(value) when is_float(value),
    do: value |> Decimal.from_float() |> Decimal.to_string(:normal)

  def decimal_input_value(value) when is_integer(value), do: Integer.to_string(value)
  def decimal_input_value(_value), do: nil

  @doc """
  Helper to create a boolean field.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.boolean_field("active", "Is Active", default: true)
      %{"type" => "boolean", "key" => "active", "label" => "Is Active", "default" => true, ...}
  """
  def boolean_field(key, label, opts \\ []) do
    new_field("boolean", key, label, opts)
  end

  @doc """
  Helper to create a rich text field.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.rich_text_field("content", "Content", required: true)
      %{"type" => "rich_text", "key" => "content", "label" => "Content", "required" => true, ...}
  """
  def rich_text_field(key, label, opts \\ []) do
    new_field("rich_text", key, label, opts)
  end

  @doc """
  Helper to create a file upload field.

  ## Examples

      iex> PhoenixKitEntities.FieldTypes.file_field("attachments", "Attachments")
      %{"type" => "file", "key" => "attachments", "label" => "Attachments", ...}

      iex> PhoenixKitEntities.FieldTypes.file_field("docs", "Documents",
           max_entries: 10, max_file_size: 52428800, accept: [".pdf", ".docx"])
      %{"type" => "file", "key" => "docs", "label" => "Documents",
        "max_entries" => 10, "max_file_size" => 52428800, "accept" => [".pdf", ".docx"], ...}
  """
  def file_field(key, label, opts \\ []) do
    base_field = new_field("file", key, label, opts)

    # Override with specific max_entries, max_file_size, accept if provided
    base_field
    |> maybe_put("max_entries", Keyword.get(opts, :max_entries))
    |> maybe_put("max_file_size", Keyword.get(opts, :max_file_size))
    |> maybe_put("accept", Keyword.get(opts, :accept))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
