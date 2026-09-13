defmodule PhoenixKitEntities.EntityData do
  @moduledoc """
  Entity data records for PhoenixKit entities system.

  This module manages actual data records that follow entity blueprints.
  Each record is associated with an entity type and stores its field values
  in a JSONB column for flexibility.

  ## Schema Fields

  - `entity_uuid`: Foreign key to the entity blueprint
  - `title`: Display title/name for the record
  - `slug`: URL-friendly identifier (optional)
  - `status`: Record status ("draft", "published", "archived", "trashed")
  - `data`: JSONB map of all field values based on entity definition
  - `metadata`: JSONB map for additional information (tags, categories, etc.)
  - `created_by`: User UUID who created the record
  - `date_created`: When the record was created
  - `date_updated`: When the record was last modified

  ## Core Functions

  ### Data Management
  - `list_all/0` - Get all entity data records (excludes trashed by default)
  - `list_by_entity/1` - Get all records for a specific entity (excludes trashed by default)
  - `list_by_entity_and_status/2` - Filter records by entity and status
  - `list_trashed_by_entity/1` - Get only trashed records for an entity
  - `get!/1` - Get a record by ID (raises if not found)
  - `get_by_slug/2` - Get a record by entity and slug (returns trashed too — slug uniqueness)
  - `create/1` - Create a new record
  - `update/2` - Update an existing record
  - `trash/1` - Soft-delete (sets status to "trashed", row stays alive — parent FKs keep resolving)
  - `restore_from_trash/1` - Move a trashed record back to "published"
  - `delete/1` - Hard-delete a record (returns `{:error, :referenced_by_external}` on FK violation)
  - `change/2` - Get changeset for forms

  ### Query Helpers
  - `search_by_title/2` - Search records by title
  - `filter_by_status/1` - Get records by status
  - `count_by_entity/1` - Count records for an entity
  - `published_records/1` - Get all published records for an entity

  ## Usage Examples

      # Create a brand data record
      {:ok, data} = PhoenixKitEntities.EntityData.create(%{
        entity_uuid: brand_entity.uuid,
        title: "Acme Corporation",
        slug: "acme-corporation",
        status: "published",
        created_by_uuid: user.uuid,
        data: %{
          "name" => "Acme Corporation",
          "tagline" => "Quality products since 1950",
          "description" => "<p>Leading manufacturer of innovative products</p>",
          "industry" => "Manufacturing",
          "founded_date" => "1950-03-15",
          "featured" => true
        },
        metadata: %{
          "tags" => ["manufacturing", "industrial"],
          "contact_email" => "info@acme.com"
        }
      })

      # Get all records for an entity
      records = PhoenixKitEntities.EntityData.list_by_entity(brand_entity.uuid)

      # Search by title
      results = PhoenixKitEntities.EntityData.search_by_title("Acme", brand_entity.uuid)
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  use Gettext, backend: PhoenixKitEntities.Gettext
  import Ecto.Changeset
  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Migrations.Postgres, as: PostgresMigrations
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.HtmlSanitizer
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.Events
  alias PhoenixKitEntities.FieldTypes
  alias PhoenixKitEntities.Managed
  alias PhoenixKitEntities.Mirror.Exporter
  alias PhoenixKitEntities.UrlResolver
  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @derive {Jason.Encoder,
           only: [
             :uuid,
             :entity_uuid,
             :parent_uuid,
             :title,
             :slug,
             :status,
             :position,
             :data,
             :metadata,
             :date_created,
             :date_updated
           ]}

  schema "phoenix_kit_entity_data" do
    field(:title, :string)
    field(:slug, :string)
    field(:status, :string, default: "published")
    field(:data, :map)
    field(:metadata, :map)
    field(:position, :integer)
    field(:created_by_uuid, UUIDv7)
    field(:date_created, :utc_datetime)
    field(:date_updated, :utc_datetime)

    belongs_to(:entity, Entities, foreign_key: :entity_uuid, references: :uuid, type: UUIDv7)

    belongs_to(:parent, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid,
      type: UUIDv7
    )

    has_many(:children, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid
    )

    belongs_to(:creator, User,
      foreign_key: :created_by_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7
    )
  end

  @valid_statuses ~w(draft published archived trashed)
  @soft_delete_status "trashed"

  # Field types whose stored value must be a single JSON scalar (or
  # absent) — see `validate_field_type/3`'s shape guard below.
  @text_like_types ~w(text textarea email url rich_text)

  # Mirrors `PhoenixKitEntities.FormBuilder`'s private sentinel for the
  # synthetic "Other" option rendered on select/radio/checkbox fields with
  # `allow_other?`. It's a UI marker only — `FormBuilder.merge_other_params/2`
  # is supposed to resolve it into the companion free-text value before it
  # ever reaches a changeset. If it somehow shows up here anyway (a caller
  # that skipped `merge_other_params/2`, or a hand-crafted request), treat
  # it as any other out-of-options value rather than letting `allow_other?`
  # wave it through.
  @other_sentinel "__other__"

  @doc """
  Creates a changeset for entity data creation and updates.

  Validates that entity exists, title is present, and data validates against entity definition.
  Automatically sets date_created on new records.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(entity_data, attrs) do
    entity_data
    |> cast(attrs, [
      :entity_uuid,
      :parent_uuid,
      :title,
      :slug,
      :status,
      :position,
      :data,
      :metadata,
      :created_by_uuid,
      :date_created,
      :date_updated
    ])
    |> validate_required([:title])
    |> validate_entity_reference()
    |> validate_creator_reference()
    |> validate_length(:title, min: 1, max: 255)
    |> validate_length(:slug, max: 255)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_slug_format()
    |> validate_not_self_parent()
    |> validate_parent_same_entity()
    |> validate_parent_not_descendant()
    |> sanitize_rich_text_data()
    |> validate_data_against_entity()
    # Core's v135 names this FK `fk_entity_data_entity_uuid`, not the
    # `phoenix_kit_entity_data_entity_uuid_fkey` that `foreign_key_constraint/2`
    # derives, so the bare declaration below matches a constraint that does not
    # exist (measured on a freshly migrated test DB and on the max-dev install —
    # both carry the `fk_` name).
    #
    # Hardening, not a live bug: `validate_data_against_entity/1` rejects a
    # missing entity with "does not exist" while the changeset is still being
    # built, so the FK never fires today and no insert reaches Postgres. This
    # keeps the declaration true if that validation is ever reordered or a
    # caller inserts a changeset directly. Both names are declared because the
    # module pins core from Hex; Ecto matches by name, so the absent one is inert.
    |> foreign_key_constraint(:entity_uuid, name: :fk_entity_data_entity_uuid)
    |> foreign_key_constraint(:entity_uuid)
    # `parent_uuid` genuinely uses the Ecto default name
    # (`phoenix_kit_entity_data_parent_uuid_fkey`), so this one is already right.
    |> foreign_key_constraint(:parent_uuid)
    |> maybe_set_timestamps()
  end

  defp validate_not_self_parent(changeset) do
    uuid = get_field(changeset, :uuid)
    parent = get_field(changeset, :parent_uuid)

    if not is_nil(uuid) and not is_nil(parent) and uuid == parent do
      add_error(changeset, :parent_uuid, gettext("a record cannot be its own parent"))
    else
      changeset
    end
  end

  # Same-entity enforcement happens here (the DB self-FK has no view of
  # entity_uuid, so we look up the parent and compare). NULL parent_uuid
  # is fine — that means "root".
  defp validate_parent_same_entity(changeset) do
    entity_uuid = get_field(changeset, :entity_uuid)
    parent_uuid = get_field(changeset, :parent_uuid)

    case {entity_uuid, parent_uuid} do
      {nil, _} -> changeset
      {_, nil} -> changeset
      {ent, parent_id} -> check_parent_entity_match(changeset, ent, parent_id)
    end
  end

  defp check_parent_entity_match(changeset, entity_uuid, parent_uuid) do
    case repo().get(__MODULE__, parent_uuid) do
      nil ->
        add_error(changeset, :parent_uuid, gettext("parent record does not exist"))

      %__MODULE__{entity_uuid: ^entity_uuid} ->
        changeset

      _other_entity ->
        add_error(
          changeset,
          :parent_uuid,
          gettext("parent must belong to the same entity")
        )
    end
  rescue
    # If the repo isn't started yet (compile-time, etc.) leave parent
    # alone — the DB-level FK will catch a bogus id at insert time.
    DBConnection.ConnectionError -> changeset
    Postgrex.Error -> changeset
  end

  # Walk up from the proposed parent toward the root; if we ever hit
  # the row we are editing, the parent assignment would create a cycle.
  # Only meaningful when both uuids are present and distinct (the
  # self-parent check covers the equal case).
  #
  # Race window: the chain is read at *validation* time, not at commit
  # time, with no row locks. Two concurrent edits on the same chain in
  # opposite directions can each pass their own validator pass and then
  # both commit, producing a cycle the DB will accept. A future fix
  # would either (a) wrap update/2 in a transaction that re-runs the
  # walk under `SELECT … FOR UPDATE` on the ancestor chain plus a
  # serializing `pg_advisory_xact_lock(hashtext(entity_uuid))` to block
  # concurrent inserts, or (b) add a Postgres BEFORE-INSERT/UPDATE
  # trigger on `parent_uuid` that runs a recursive-CTE acyclicity
  # check and aborts. Option (b) ships from the companion migration
  # repo; tracked as a follow-up. The in-memory walk caps at
  # `@max_ancestor_depth` so even if a pre-existing cycle slips
  # through, the validator can't loop forever.
  defp validate_parent_not_descendant(changeset) do
    uuid = get_field(changeset, :uuid)
    parent_uuid = get_field(changeset, :parent_uuid)

    case {uuid, parent_uuid} do
      {nil, _} -> changeset
      {_, nil} -> changeset
      {same, same} -> changeset
      {self_id, parent_id} -> check_no_cycle(changeset, self_id, parent_id)
    end
  end

  defp check_no_cycle(changeset, self_id, parent_id) do
    if ancestor_chain_contains?(parent_id, self_id, 0) do
      add_error(
        changeset,
        :parent_uuid,
        gettext("parent cannot be one of this record's descendants")
      )
    else
      changeset
    end
  rescue
    DBConnection.ConnectionError -> changeset
    Postgrex.Error -> changeset
  end

  # Bounded walk — a tree this deep is a bug, but the guard keeps the
  # validator from looping forever if the DB somehow already has a
  # cycle (shouldn't happen, but be defensive).
  @max_ancestor_depth 64

  defp ancestor_chain_contains?(_uuid, _target, depth) when depth >= @max_ancestor_depth,
    do: false

  defp ancestor_chain_contains?(uuid, target, depth) do
    case repo().get(__MODULE__, uuid) do
      nil -> false
      %__MODULE__{parent_uuid: nil} -> false
      %__MODULE__{parent_uuid: ^target} -> true
      %__MODULE__{parent_uuid: next} -> ancestor_chain_contains?(next, target, depth + 1)
    end
  end

  defp validate_entity_reference(changeset) do
    entity_uuid = get_field(changeset, :entity_uuid)

    if is_nil(entity_uuid) do
      add_error(changeset, :entity_uuid, gettext("entity_uuid must be present"))
    else
      changeset
    end
  end

  # `phoenix_kit_entity_data.created_by_uuid` is NOT NULL in core's chain, and
  # `create/2` documents that a missing creator surfaces "a validation error on
  # created_by" when no user exists to auto-fill from. Without this the insert
  # reaches Postgres and raises 23502 instead — the same shape `Entity` already
  # guards against with its own `validate_creator_reference/1`.
  #
  # INSERTS ONLY. `changeset/2` is shared with `update/3`, and installs that
  # migrated before the constraint was enforced hold rows with a NULL creator
  # (#706 measured 4 of 26 on a live database, where the column is still
  # nullable because V164 declines to re-impose NOT NULL while NULLs exist).
  # Validating those on update would reject an edit that never touched
  # `created_by_uuid` — retitling a legacy public submission would fail.
  defp validate_creator_reference(%Ecto.Changeset{data: %{__meta__: %{state: :loaded}}} = cs),
    do: cs

  defp validate_creator_reference(changeset) do
    cond do
      not is_nil(get_field(changeset, :created_by_uuid)) -> changeset
      # From V169 a missing creator is a supported value, not an error: that is
      # what an anonymous public submission looks like.
      anonymous_creator_supported?() -> changeset
      true -> add_error(changeset, :created_by_uuid, gettext("created_by_uuid must be present"))
    end
  end

  defp validate_slug_format(changeset) do
    case get_field(changeset, :slug) do
      nil ->
        changeset

      "" ->
        changeset

      slug ->
        if Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, slug) do
          changeset
        else
          add_error(
            changeset,
            :slug,
            gettext("must contain only lowercase letters, numbers, and hyphens")
          )
        end
    end
  end

  defp sanitize_rich_text_data(changeset) do
    entity_uuid = get_field(changeset, :entity_uuid)
    data = get_field(changeset, :data)

    case {entity_uuid, data} do
      {nil, _} ->
        changeset

      {_, nil} ->
        changeset

      {id, data} ->
        try do
          entity = Entities.get_entity!(id)
          fields_definition = entity.fields_definition || []

          sanitized_data =
            if Multilang.multilang_data?(data) do
              # Sanitize each language's data independently
              Enum.reduce(data, %{}, fn
                {"_primary_language", value}, acc ->
                  Map.put(acc, "_primary_language", value)

                {lang_code, lang_data}, acc when is_map(lang_data) ->
                  sanitized =
                    HtmlSanitizer.sanitize_rich_text_fields(fields_definition, lang_data)

                  Map.put(acc, lang_code, sanitized)

                {key, value}, acc ->
                  Map.put(acc, key, value)
              end)
            else
              HtmlSanitizer.sanitize_rich_text_fields(fields_definition, data)
            end

          put_change(changeset, :data, sanitized_data)
        rescue
          Ecto.NoResultsError -> changeset
        end
    end
  end

  defp validate_data_against_entity(changeset) do
    entity_uuid = get_field(changeset, :entity_uuid)
    data = get_field(changeset, :data)

    case entity_uuid do
      nil ->
        changeset

      uuid ->
        # Use `get_entity/1` (returns nil) instead of `get_entity!/1` so the
        # missing-FK case flows through `add_error` rather than `rescue`.
        case Entities.get_entity(uuid) do
          nil ->
            add_error(changeset, :entity_uuid, gettext("does not exist"))

          entity ->
            validate_data_fields(changeset, entity, data || %{})
        end
    end
  rescue
    Ecto.QueryError ->
      add_error(changeset, :entity_uuid, gettext("does not exist"))
  end

  defp validate_data_fields(changeset, entity, data) do
    fields_definition = entity.fields_definition || []

    # For multilang data, validate the primary language data (which must be complete)
    validation_data =
      if Multilang.multilang_data?(data) do
        Multilang.get_primary_data(data)
      else
        data
      end

    Enum.reduce(fields_definition, changeset, fn field_def, acc ->
      validate_single_data_field(acc, field_def, validation_data)
    end)
  end

  # Display-only — no data to validate or require.
  defp validate_single_data_field(changeset, %{"type" => "heading"}, _data), do: changeset

  defp validate_single_data_field(changeset, field_def, data) do
    field_key = field_def["key"]
    field_value = data[field_key]
    is_required = field_def["required"] || false

    cond do
      # `[]` is what an unticked (or never-touched) required checkbox
      # group submits — it must count as "absent" here the same way
      # `FormBuilder.validate_required/2` (form_builder.ex) already treats
      # `value in [nil, "", []]` as missing. Before this, an empty
      # required checkbox sailed through this changeset check (only
      # `nil`/`""` were caught) while `FormBuilder.validate_data/2`
      # rejected it — the two disagreed, and `LiveDataForm` relies on
      # this changeset being the final, strict word.
      is_required && field_value in [nil, "", []] ->
        add_error(
          changeset,
          :data,
          gettext("field '%{label}' is required", label: field_def["label"])
        )

      !is_nil(field_value) && field_value != "" ->
        validate_field_type(changeset, field_def, field_value)

      true ->
        changeset
    end
  end

  # SECURITY: this `case` used to have no branch at all for
  # `text`/`textarea`/`rich_text` — they fell through to the catch-all
  # (`_ -> changeset`), so `EntityData.changeset/2`, the FINAL,
  # unconditional word on what lands in `data` (see this module's
  # moduledoc / `LiveDataForm`'s own doc for why every other check here
  # is best-effort), had no opinion on their value's shape. A map (or any
  # other non-scalar term) sailed straight through and into storage.
  #
  # Every surface that renders a `text`/`textarea`/`rich_text` value does
  # so naively: the readonly view calls `to_string/1` on it
  # (`PhoenixKitEntities.Components.LiveDataForm.readonly_text/1` /
  # `readonly_value/1`), the edit form interpolates it directly inside
  # `<textarea>{@value}</textarea>` (`FormBuilder.build_field/3`) — a
  # stored map raises `Protocol.UndefinedError` in both, crashing
  # rendering for every subsequent viewer of the record. `LiveDataForm`
  # now sanitizes by field type before a value ever reaches this
  # changeset (see its `sanitize_values/2`), but this is the module's own
  # final gate, reachable from the admin `DataForm` and the public
  # `EntityForm` too — it must reject the same shapes independent of any
  # particular caller.
  #
  # `email`/`url` are included in the same shape check (rather than left
  # to fall through to `validate_email_field/3` / `validate_url_field/3`
  # below) for a uniform, purpose-built error message on a shape
  # mismatch; those two already separately guard on `is_binary(value)`
  # before doing anything else, so this doesn't change what they accept —
  # only which message a non-text value gets. `number`/`boolean`/`date`
  # are NOT included: `number`/`boolean` have their own type coercion
  # rules (a bare shape check would be either too strict or redundant —
  # see `LiveDataForm.sanitize_field_value/2`'s narrower number/boolean
  # clauses for that reasoning), and `validate_date_field/3` already
  # guards on `is_binary(value)` the same way email/url do.
  defp validate_field_type(changeset, field_def, value) do
    type = field_def["type"]

    if type in @text_like_types and not text_like_shape?(value) do
      add_error(
        changeset,
        :data,
        gettext("field '%{label}' must be a text value", label: field_def["label"])
      )
    else
      dispatch_field_type_validation(changeset, type, field_def, value)
    end
  end

  defp text_like_shape?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  # Split out of `validate_field_type/3` (rather than nested in its `else`
  # branch) purely to keep each function's cyclomatic complexity under
  # `credo --strict`'s threshold — no behavior difference from having it
  # inline.
  defp dispatch_field_type_validation(changeset, type, field_def, value) do
    case type do
      "number" ->
        validate_number_field(changeset, field_def, value)

      "decimal" ->
        validate_decimal_field(changeset, field_def, value)

      "boolean" ->
        validate_boolean_field(changeset, field_def, value)

      "email" ->
        validate_email_field(changeset, field_def, value)

      "url" ->
        validate_url_field(changeset, field_def, value)

      "date" ->
        validate_date_field(changeset, field_def, value)

      _ ->
        dispatch_choice_or_media_validation(changeset, type, field_def, value)
    end
  end

  # Second half of the dispatch — split only to keep each function's
  # cyclomatic complexity under `credo --strict`'s threshold.
  defp dispatch_choice_or_media_validation(changeset, type, field_def, value) do
    case type do
      type when type in ["select", "radio"] ->
        validate_choice_field(changeset, field_def, value)

      "checkbox" ->
        validate_checkbox_field(changeset, field_def, value)

      type when type in ["image", "video"] ->
        validate_media_field(changeset, field_def, value)

      _ ->
        changeset
    end
  end

  # Media references store a storage file uuid; this is the module's
  # final gate (same doctrine as the text-like shape check above), so a
  # crafted write cannot land a shape that crashes uuid-resolving
  # renderers downstream.
  defp validate_media_field(changeset, field_def, value) do
    with true <- is_binary(value),
         {:ok, _} <- Ecto.UUID.cast(value) do
      changeset
    else
      _ ->
        add_error(
          changeset,
          :data,
          gettext("field '%{label}' must be a media file reference",
            label: field_def["label"]
          )
        )
    end
  end

  defp validate_number_field(changeset, field_def, value) do
    if is_number(value) || (is_binary(value) && Regex.match?(~r/^\d+(\.\d+)?$/, value)) do
      changeset
    else
      add_error(
        changeset,
        :data,
        gettext("field '%{label}' must be a number", label: field_def["label"])
      )
    end
  end

  # The shape guard for exact numerics. A `%Decimal{}` is what a fresh
  # cast produces; a canonical string is what comes back out of JSONB,
  # since JSON has no decimal and serialising through a float would undo
  # the whole point of the type.
  defp validate_decimal_field(changeset, field_def, value) do
    if decimal_shaped?(value) do
      changeset
    else
      add_error(
        changeset,
        :data,
        gettext("field '%{label}' must be a number", label: field_def["label"])
      )
    end
  end

  defp decimal_shaped?(%Decimal{}), do: true
  defp decimal_shaped?(value) when is_number(value), do: true

  # Trimmed before parsing, to match what `FormBuilder.cast_field/2` accepts.
  # Without this a hand-written `" 5.1 "` casts fine on the way in and is then
  # refused by this guard on re-save.
  defp decimal_shaped?(value) when is_binary(value) do
    match?({_decimal, ""}, value |> String.trim() |> Decimal.parse())
  end

  defp decimal_shaped?(_value), do: false

  defp validate_boolean_field(changeset, field_def, value) do
    if is_boolean(value) do
      changeset
    else
      add_error(
        changeset,
        :data,
        gettext("field '%{label}' must be true or false", label: field_def["label"])
      )
    end
  end

  defp validate_email_field(changeset, field_def, value) do
    if is_binary(value) && Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, value) do
      changeset
    else
      add_error(
        changeset,
        :data,
        gettext("field '%{label}' must be a valid email", label: field_def["label"])
      )
    end
  end

  defp validate_url_field(changeset, field_def, value) do
    if is_binary(value) && String.starts_with?(value, ["http://", "https://"]) do
      changeset
    else
      add_error(
        changeset,
        :data,
        gettext("field '%{label}' must be a valid URL", label: field_def["label"])
      )
    end
  end

  defp validate_date_field(changeset, field_def, value) do
    if is_binary(value) && Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, value) do
      changeset
    else
      add_error(
        changeset,
        :data,
        gettext("field '%{label}' must be a valid date (YYYY-MM-DD)", label: field_def["label"])
      )
    end
  end

  # Shared scalar (single-value) choice validator for "select" and "radio"
  # — both are "pick exactly one" fields with the same options/allow_other
  # shape. The sentinel check comes first and applies unconditionally: it
  # must never validate as a real value, allow_other or not (see
  # `@other_sentinel`).
  #
  # SECURITY (M2 follow-up): the `allow_other?` branch used to accept
  # ANY value unconditionally — including a crafted map — once a value
  # wasn't a recognized option. `allow_other`'s whole premise is a
  # free-text custom answer, i.e. a string; nothing else is a legitimate
  # "Other" value. This reaches the same render surfaces text/textarea
  # values do (`readonly_field/3`'s `select`/`radio` clause resolves the
  # stored value through `FormBuilder.translated_option_label/3`, which
  # falls back to the raw value and interpolates it via `{@display}` —
  # `Protocol.UndefinedError` for a map, same as the text-field crash
  # this module's `validate_field_type/3` shape guard already closes) —
  # and, unlike `text`/`textarea`, this path is also reachable from the
  # public, unauthenticated `EntityForm` (not just `LiveDataForm`, whose
  # own `sanitize_values/2` already covers this specific gap for its
  # path), so this changeset-level fix is the only thing closing it
  # there.
  defp validate_choice_field(changeset, field_def, value) do
    options = field_def["options"] || []

    cond do
      value == @other_sentinel ->
        add_error(
          changeset,
          :data,
          gettext("field '%{label}' has an invalid value", label: field_def["label"])
        )

      value in options ->
        changeset

      FieldTypes.allow_other?(field_def) and is_binary(value) ->
        changeset

      true ->
        add_error(
          changeset,
          :data,
          gettext("field '%{label}' must be one of: %{options}",
            label: field_def["label"],
            options: Enum.join(options, ", ")
          )
        )
    end
  end

  # Checkbox groups are multi-value — every submitted entry must be
  # in `options` (or allowed via `allow_other?`, but never the
  # `@other_sentinel` marker itself). A non-list value (e.g. a single
  # scalar string crafted into the request) is rejected outright rather
  # than silently passing through unvalidated.
  #
  # SECURITY (M2 follow-up): same `allow_other` shape gap as
  # `validate_choice_field/3` above, one level down — an out-of-options
  # LIST ELEMENT used to be waved through unconditionally when
  # `allow_other` was set, map elements included. Now an out-of-options
  # element is only accepted when it's ALSO a binary — `allow_other`
  # means "one free-text custom entry", not "any term".
  defp validate_checkbox_field(changeset, field_def, value) when is_list(value) do
    options = field_def["options"] || []
    allow_other = FieldTypes.allow_other?(field_def)

    invalid_values =
      Enum.filter(value, fn v ->
        v == @other_sentinel or (v not in options and (not allow_other or not is_binary(v)))
      end)

    if Enum.empty?(invalid_values) do
      changeset
    else
      add_error(
        changeset,
        :data,
        gettext("field '%{label}' contains invalid options: %{invalid}",
          label: field_def["label"],
          # Not Enum.join/2: the is_binary/1 guard above is what routes a
          # non-binary term into invalid_values in the first place, so joining
          # would raise Protocol.UndefinedError while building the very error
          # that rejects it — trading a stored bad value for an attacker
          # -triggered crash. Same treatment FormBuilder already gives its copy
          # of this message.
          invalid: Enum.map_join(invalid_values, ", ", &stringify_invalid_option/1)
        )
      )
    end
  end

  defp validate_checkbox_field(changeset, field_def, _value) do
    add_error(
      changeset,
      :data,
      gettext("field '%{label}' must be a list of selected options", label: field_def["label"])
    )
  end

  defp stringify_invalid_option(value) when is_binary(value), do: value
  defp stringify_invalid_option(value), do: inspect(value)

  defp maybe_set_timestamps(changeset) do
    now = UtilsDate.utc_now()

    case changeset.data.__meta__.state do
      :built ->
        changeset
        |> put_change(:date_created, now)
        |> put_change(:date_updated, now)

      :loaded ->
        put_change(changeset, :date_updated, now)
    end
  end

  defp notify_data_event({:ok, %__MODULE__{} = entity_data}, :created, opts) do
    Events.broadcast_data_created(entity_data.entity_uuid, entity_data.uuid)
    maybe_mirror_data(entity_data)
    maybe_log_data_activity(entity_data, "entity_data.created", opts)
    {:ok, entity_data}
  end

  defp notify_data_event({:ok, %__MODULE__{} = entity_data}, :updated, opts) do
    Events.broadcast_data_updated(entity_data.entity_uuid, entity_data.uuid)
    maybe_mirror_data(entity_data)
    maybe_log_data_activity(entity_data, "entity_data.updated", opts)
    {:ok, entity_data}
  end

  defp notify_data_event({:ok, %__MODULE__{} = entity_data}, :deleted, opts) do
    Events.broadcast_data_deleted(entity_data.entity_uuid, entity_data.uuid)
    maybe_delete_mirrored_data(entity_data)
    maybe_log_data_activity(entity_data, "entity_data.deleted", opts)
    {:ok, entity_data}
  end

  defp notify_data_event({:ok, %__MODULE__{} = entity_data}, :trashed, opts) do
    Events.broadcast_data_updated(entity_data.entity_uuid, entity_data.uuid)
    # Re-export so the trashed record drops out of the mirror file
    # (mirror queries default to non-trashed via list_data_by_entity).
    maybe_mirror_data(entity_data)
    log_data_activity(entity_data, "entity_data.trashed", opts)
    {:ok, entity_data}
  end

  defp notify_data_event({:ok, %__MODULE__{} = entity_data}, :restored, opts) do
    Events.broadcast_data_updated(entity_data.entity_uuid, entity_data.uuid)
    maybe_mirror_data(entity_data)
    log_data_activity(entity_data, "entity_data.restored", opts)
    {:ok, entity_data}
  end

  defp notify_data_event({:error, _} = result, event, opts) do
    # `activity_log: false` (see `maybe_log_data_activity/3` below) must
    # suppress this error-path row too, not just the success path.
    # `EntityData.changeset/2` re-validates every required field on EVERY
    # `update/3` call, so a `LiveDataForm` autosave against an
    # incomplete-required-field record fails this changeset on every
    # debounced keystroke until the last required field is filled — without
    # this guard, each of those failures would still insert a
    # `db_pending: true` activity row, flooding the log exactly the way
    # `activity_log: false` exists to prevent.
    if Keyword.get(opts, :activity_log, true) do
      log_data_error_activity(event, opts)
    end

    result
  end

  defp notify_data_event(result, _event, _opts), do: result

  # `opts[:activity_log]` defaults to `true`. Passing `false` skips the
  # activity-log entry for this update while leaving the PubSub
  # broadcast and mirror export (both above, in `notify_data_event/3`)
  # untouched — those still need to fire so live views/mirrors stay in
  # sync. Used by high-frequency callers (`LiveDataForm` autosave) so a
  # client that's still typing doesn't produce one activity row per
  # debounced keystroke, and by owning modules that write their own
  # richer domain row instead (e.g. the catalogue's
  # `attribute_set.value_deleted`) — an explicit `activity_log: false`
  # is honored on every lifecycle event, matching the error path above.
  defp maybe_log_data_activity(entity_data, action, opts) do
    if Keyword.get(opts, :activity_log, true) do
      log_data_activity(entity_data, action, opts)
    else
      :ok
    end
  end

  # Records a data-record-lifecycle activity entry. Actor UUID comes
  # from caller's `:actor_uuid` opt (the user performing the mutation)
  # rather than `entity_data.created_by_uuid` (the original creator).
  # Non-crashing — see `PhoenixKitEntities.ActivityLog` for the guard
  # semantics.
  defp log_data_activity(%__MODULE__{} = entity_data, action, opts) do
    PhoenixKitEntities.ActivityLog.log(%{
      action: action,
      mode: "manual",
      actor_uuid: activity_actor(entity_data, opts),
      resource_type: "entity_data",
      resource_uuid: entity_data.uuid,
      metadata: %{
        "entity_uuid" => entity_data.entity_uuid,
        "title" => entity_data.title,
        "slug" => entity_data.slug,
        "status" => entity_data.status
      }
    })
  end

  # An explicitly passed `:actor_uuid` wins even when it is nil — the same
  # explicit-nil-vs-absent distinction the creator auto-fill makes. An
  # unauthenticated public submission has no actor, and falling back to
  # `created_by_uuid` would file it in the audit trail under whoever the
  # auto-fill picked (the first Owner), reading as if that person posted it.
  # Callers that simply do not know the actor still get the old fallback.
  defp activity_actor(%__MODULE__{} = entity_data, opts) do
    case Keyword.fetch(opts, :actor_uuid) do
      {:ok, actor_uuid} -> actor_uuid
      :error -> entity_data.created_by_uuid
    end
  end

  # Records a user-initiated data-record action even when the changeset
  # failed. Marked with `db_pending: true` so consumers can distinguish
  # from successful rows.
  defp log_data_error_activity(event, opts) do
    PhoenixKitEntities.ActivityLog.log(%{
      action: "entity_data.#{event}",
      mode: "manual",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "entity_data",
      metadata: %{"db_pending" => true}
    })
  end

  # Broadcast a reorder event for an entity so live views refresh.
  # Builds the WHERE clause for `bulk_update_positions/2`. When a
  # scope uuid is supplied, the entity_uuid filter prevents a stray
  # cross-entity uuid in the input list from rewriting positions in
  # the wrong scope.
  defp position_update_query(uuid, nil),
    do: from(d in __MODULE__, where: d.uuid == ^uuid)

  defp position_update_query(uuid, scope) when is_binary(scope),
    do: from(d in __MODULE__, where: d.uuid == ^uuid and d.entity_uuid == ^scope)

  defp position_update_query(_uuid, scope),
    do:
      raise(
        ArgumentError,
        "expected entity_uuid scope to be a binary UUID or nil, got: #{inspect(scope)}"
      )

  # Audit-log a completed reorder. `count` is the number of rows the
  # transaction actually wrote, not the number of pairs submitted.
  defp log_data_reorder(uuid_position_pairs, written, entity_uuid, opts) do
    PhoenixKitEntities.ActivityLog.log(%{
      action: "entity_data.reordered",
      mode: "manual",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "entity_data",
      resource_uuid: first_uuid_from_pairs(uuid_position_pairs),
      metadata: %{
        "entity_uuid" => entity_uuid,
        "count" => written
      }
    })
  end

  # Audit-log a reorder failure so the user-initiated action is
  # represented in the activity table even when the DB write rolls
  # back. `db_pending: true` lets consumers distinguish from
  # successful rows.
  defp log_data_reorder_error(uuid_position_pairs, entity_uuid_scope, _reason, opts) do
    PhoenixKitEntities.ActivityLog.log(%{
      action: "entity_data.reordered",
      mode: "manual",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "entity_data",
      resource_uuid: first_uuid_from_pairs(uuid_position_pairs),
      metadata: %{
        "entity_uuid" => entity_uuid_scope,
        "count" => length(uuid_position_pairs),
        "db_pending" => true
      }
    })
  end

  # Audit-log an early-rejection (oversized payload). Same shape as
  # the error path; flagged with `rejected:` so audit consumers can
  # tell rejection apart from a DB failure.
  defp log_data_reorder_rejected(reason, count, opts) do
    PhoenixKitEntities.ActivityLog.log(%{
      action: "entity_data.reordered",
      mode: "manual",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "entity_data",
      metadata: %{
        "entity_uuid" => Keyword.get(opts, :entity_uuid),
        "count" => count,
        "db_pending" => true,
        "rejected" => to_string(reason)
      }
    })
  end

  defp first_uuid_from_pairs([{uuid, _} | _]) when is_binary(uuid), do: uuid
  defp first_uuid_from_pairs(_), do: nil

  defp notify_reorder_event(entity_uuid) when is_binary(entity_uuid) do
    Events.broadcast_data_reordered(entity_uuid)
  end

  defp notify_reorder_event(_), do: :ok

  # Resolve entity_uuid from the first record in a bulk update list
  defp resolve_entity_uuid_from_pairs([{uuid, _} | _]) do
    from(d in __MODULE__, where: d.uuid == ^uuid, select: d.entity_uuid)
    |> repo().one()
  end

  defp resolve_entity_uuid_from_pairs(_), do: nil

  # Mirror export helpers for auto-sync (per-entity settings).
  # Supervised under PhoenixKit.TaskSupervisor for fire-and-forget
  # after-DB-commit work — a crashing exporter shouldn't propagate.
  defp maybe_mirror_data(entity_data) do
    with entity when not is_nil(entity) <- Entities.get_entity(entity_data.entity_uuid),
         true <- Entities.mirror_data_enabled?(entity) do
      Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, fn ->
        Exporter.export_entity_data(entity_data)
      end)
    end

    :ok
  end

  defp maybe_delete_mirrored_data(entity_data) do
    with entity when not is_nil(entity) <- Entities.get_entity(entity_data.entity_uuid),
         true <- Entities.mirror_data_enabled?(entity) do
      Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, fn ->
        Exporter.export_entity(entity)
      end)
    end

    :ok
  end

  @doc """
  Returns all entity data records ordered by creation date.

  Trashed records are excluded by default. Pass `include_trashed: true` to
  return them too — used by admin trash views and reverse-reference checks.

  ## Examples

      iex> PhoenixKitEntities.EntityData.list_all()
      [%PhoenixKitEntities.EntityData{}, ...]
  """
  @spec list_all(keyword()) :: [t()]
  def list_all(opts \\ []) do
    from(d in __MODULE__,
      order_by: [desc: d.date_created],
      preload: [:entity, :creator]
    )
    |> exclude_trashed(opts)
    |> repo().all()
    |> maybe_resolve_langs(opts)
  end

  @doc """
  Returns all entity data records for a specific entity.

  Trashed records are excluded by default. Pass `include_trashed: true` to
  return them too.

  ## Examples

      iex> PhoenixKitEntities.EntityData.list_by_entity(entity_uuid)
      [%PhoenixKitEntities.EntityData{}, ...]
  """
  @spec list_by_entity(binary(), keyword()) :: [t()]
  def list_by_entity(entity_uuid, opts \\ []) when is_binary(entity_uuid) do
    order = resolve_sort_order(entity_uuid, opts)

    from(d in __MODULE__,
      where: d.entity_uuid == ^entity_uuid,
      order_by: ^order,
      preload: [:entity, :creator]
    )
    |> exclude_trashed(opts)
    |> maybe_limit(opts[:limit])
    |> repo().all()
    |> maybe_resolve_langs(opts)
  end

  defp maybe_limit(query, n) when is_integer(n) and n > 0, do: limit(query, ^n)
  defp maybe_limit(query, _), do: query

  @doc """
  Records for MANY entities at once: `%{entity_uuid => [record]}`.

  The batched twin of `list_by_entity/2`, for a caller holding a list of
  entities that needs the rows of each — a filter offering one dropdown
  per attribute set, say. The loop version costs two queries per entity
  (the sort mode, then the rows) and grows with the data.

  Options:

    * `:exclude_statuses` — drop records in these statuses (e.g.
      `["archived"]`). Applied in SQL, which is what makes `:limit`
      exact: filtering after a limited fetch silently returns fewer
      rows than asked for and reads as "that's all there is".
    * `:limit` — at most this many records PER entity, after filtering.
    * `:include_trashed`, `:lang` — as `list_by_entity/2`.
    * `:preload` — defaults to `[:entity, :creator]`; pass `[]` when the
      caller only reads the record's own columns.

  Entities with no matching records are absent from the map — use
  `Map.get(result, uuid, [])`.
  """
  @spec list_by_entities([binary()], keyword()) :: %{optional(binary()) => [t()]}
  def list_by_entities(entity_uuids, opts \\ [])
  def list_by_entities([], _opts), do: %{}

  def list_by_entities(entity_uuids, opts) when is_list(entity_uuids) do
    uuids = Enum.uniq(entity_uuids)
    modes = sort_modes_for(uuids)
    limit = opts[:limit]

    query =
      from(d in __MODULE__,
        where: d.entity_uuid in ^uuids,
        preload: ^Keyword.get(opts, :preload, [:entity, :creator])
      )
      |> exclude_trashed(opts)
      |> exclude_statuses(opts)

    query
    |> repo().all()
    |> maybe_resolve_langs(opts)
    |> Enum.group_by(& &1.entity_uuid)
    |> Map.new(fn {uuid, rows} ->
      rows = sort_rows(rows, modes[uuid])
      {uuid, if(is_integer(limit) and limit > 0, do: Enum.take(rows, limit), else: rows)}
    end)
  end

  defp exclude_statuses(query, opts) do
    case opts[:exclude_statuses] do
      statuses when is_list(statuses) and statuses != [] ->
        from(d in query, where: d.status not in ^statuses)

      _ ->
        query
    end
  end

  defp sort_modes_for(entity_uuids) do
    from(e in Entities, where: e.uuid in ^entity_uuids, select: {e.uuid, e.settings})
    |> repo().all()
    |> Map.new(fn
      {uuid, %{"sort_mode" => mode}} -> {uuid, mode}
      {uuid, _} -> {uuid, "auto"}
    end)
  end

  # Mirrors `sort_order_for_mode/1` for an already-loaded batch. The two
  # must agree: a set whose values are hand-ordered has to come back in
  # that order whichever function loaded it, and nothing but a test
  # holds them together (`entity_data_batch_counts_test.exs`).
  defp sort_rows(rows, "manual") do
    Enum.sort_by(rows, &{is_nil(&1.position), &1.position, inverted_date(&1.date_created)})
  end

  defp sort_rows(rows, _auto) do
    Enum.sort_by(rows, &inverted_date(&1.date_created))
  end

  # `desc: :date_created` inside an otherwise ascending sort key.
  defp inverted_date(nil), do: nil
  defp inverted_date(%DateTime{} = dt), do: -DateTime.to_unix(dt, :microsecond)

  defp inverted_date(%NaiveDateTime{} = dt),
    do: -(dt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond))

  @doc """
  Returns the entity's records as a depth-ordered flat list for
  WordPress-style indented rendering — parents precede their children,
  siblings preserve the entity's current sort order.

  Each element is `%{record: %EntityData{}, depth: integer}` where
  depth `0` is a root row.

  ## Options

  * `:include_trashed` — when `true`, include trashed rows (default `false`)
  * `:lang` — resolve multilingual fields to the given locale. Display-only —
    see the warning on `resolve_language/2` before writing a resolved record back
  * any other opt accepted by `list_by_entity/2`
  """
  @spec list_tree(binary(), keyword()) :: [%{record: t(), depth: non_neg_integer()}]
  def list_tree(entity_uuid, opts \\ []) when is_binary(entity_uuid) do
    entity_uuid
    |> list_by_entity(opts)
    |> tree_from_rows()
  end

  @doc """
  Depth-orders an already-loaded list of rows. Use this when the caller
  already has the rows in hand (e.g. building both a tree and a
  descendants set from the same fetch) — skips the per-call DB hit
  that `list_tree/2` makes.
  """
  @spec tree_from_rows([t()]) :: [%{record: t(), depth: non_neg_integer()}]
  def tree_from_rows(rows) when is_list(rows), do: build_tree(rows)

  @doc """
  Returns all descendant UUIDs of a record (children, grandchildren, …).

  Used by the parent picker to exclude rows that would create a cycle.
  Walks the in-memory tree of the same entity rather than recursing
  through the DB. Trashed rows are excluded by default — they cannot
  meaningfully participate in a new cycle and including them would
  leak trashed rows into the picker's exclusion set.

  Returns `[]` for unknown / NULL `uuid`.

  ## Options

  * `:include_trashed` — when `true`, include trashed descendants
  """
  @spec descendant_uuids(binary() | nil, binary(), keyword()) :: [binary()]
  def descendant_uuids(uuid, entity_uuid, opts \\ [])

  def descendant_uuids(nil, _entity_uuid, _opts), do: []

  def descendant_uuids(uuid, entity_uuid, opts)
      when is_binary(uuid) and is_binary(entity_uuid) do
    rows = list_by_entity(entity_uuid, opts)
    descendant_uuids_from_rows(uuid, rows)
  end

  @doc """
  Same as `descendant_uuids/3` but operates on an already-loaded row
  list. Pair with `tree_from_rows/1` when both shapes are needed from
  one fetch.
  """
  @spec descendant_uuids_from_rows(binary() | nil, [t()]) :: [binary()]
  def descendant_uuids_from_rows(nil, _rows), do: []

  def descendant_uuids_from_rows(uuid, rows) when is_binary(uuid) and is_list(rows) do
    collect_descendants(uuid, group_by_parent(rows), [])
  end

  # Build a depth-ordered flat list from a sibling-ordered row list.
  # Rows whose parent_uuid points outside the input set surface as
  # roots (defensive — a misaligned parent reference can't hide rows
  # from the admin view).
  defp build_tree(rows) do
    by_parent = group_by_parent(rows)
    known_uuids = MapSet.new(rows, & &1.uuid)

    roots =
      Enum.filter(rows, fn row ->
        is_nil(row.parent_uuid) or not MapSet.member?(known_uuids, row.parent_uuid)
      end)

    Enum.flat_map(roots, &walk_tree(&1, by_parent, 0))
  end

  defp walk_tree(row, by_parent, depth) do
    children = Map.get(by_parent, row.uuid, [])
    [%{record: row, depth: depth} | Enum.flat_map(children, &walk_tree(&1, by_parent, depth + 1))]
  end

  defp group_by_parent(rows) do
    Enum.group_by(rows, & &1.parent_uuid)
  end

  defp collect_descendants(uuid, children_by_parent, acc) do
    case Map.get(children_by_parent, uuid, []) do
      [] ->
        acc

      children ->
        Enum.reduce(children, acc, fn child, inner_acc ->
          collect_descendants(child.uuid, children_by_parent, [child.uuid | inner_acc])
        end)
    end
  end

  @doc """
  Returns trashed records for a specific entity, ordered by most recently
  updated (the default trash-bin view).

  ## Examples

      iex> PhoenixKitEntities.EntityData.list_trashed_by_entity(entity_uuid)
      [%PhoenixKitEntities.EntityData{status: "trashed"}, ...]
  """
  @spec list_trashed_by_entity(binary(), keyword()) :: [t()]
  def list_trashed_by_entity(entity_uuid, opts \\ []) when is_binary(entity_uuid) do
    from(d in __MODULE__,
      where: d.entity_uuid == ^entity_uuid and d.status == ^@soft_delete_status,
      order_by: [desc: d.date_updated],
      preload: [:entity, :creator]
    )
    |> repo().all()
    |> maybe_resolve_langs(opts)
  end

  # Appends `where: status != "trashed"` unless caller opted in via
  # `include_trashed: true`. Public consumers (sitemap, mirror exporter,
  # admin default views) get the safe-by-default exclusion; trash-tab
  # views and reverse-reference checks pass `include_trashed: true`.
  defp exclude_trashed(query, opts) do
    if Keyword.get(opts, :include_trashed, false) do
      query
    else
      from(d in query, where: d.status != ^@soft_delete_status)
    end
  end

  @doc """
  Returns entity data records filtered by entity and status.

  ## Examples

      iex> PhoenixKitEntities.EntityData.list_by_entity_and_status(entity_uuid, "published")
      [%PhoenixKitEntities.EntityData{status: "published"}, ...]
  """
  @spec list_by_entity_and_status(binary(), String.t(), keyword()) :: [t()]
  def list_by_entity_and_status(entity_uuid, status, opts \\ [])
      when is_binary(entity_uuid) and status in @valid_statuses do
    order = resolve_sort_order(entity_uuid, opts)

    from(d in __MODULE__,
      where: d.entity_uuid == ^entity_uuid and d.status == ^status,
      order_by: ^order,
      preload: [:entity, :creator]
    )
    |> repo().all()
    |> maybe_resolve_langs(opts)
  end

  @doc """
  Gets a single entity data record by UUID.

  Returns the record if found, nil otherwise.

  ## Examples

      iex> PhoenixKitEntities.EntityData.get("550e8400-e29b-41d4-a716-446655440000")
      %PhoenixKitEntities.EntityData{}

      iex> PhoenixKitEntities.EntityData.get("invalid")
      nil
  """
  @spec get(any(), keyword()) :: t() | nil
  def get(uuid, opts \\ [])

  def get(uuid, opts) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid) do
      case repo().get_by(__MODULE__, uuid: uuid) do
        nil -> nil
        record -> record |> repo().preload([:entity, :creator]) |> maybe_resolve_lang(opts)
      end
    else
      nil
    end
  end

  def get(_, _opts), do: nil

  @doc """
  Gets a single entity data record by UUID.

  Raises `Ecto.NoResultsError` if the record does not exist.

  ## Examples

      iex> PhoenixKitEntities.EntityData.get!("550e8400-e29b-41d4-a716-446655440000")
      %PhoenixKitEntities.EntityData{}

      iex> PhoenixKitEntities.EntityData.get!("nonexistent-uuid")
      ** (Ecto.NoResultsError)
  """
  @spec get!(binary(), keyword()) :: t()
  def get!(id, opts \\ []) do
    case get(id, opts) do
      nil -> raise Ecto.NoResultsError, queryable: __MODULE__
      record -> record
    end
  end

  @doc """
  Gets a single entity data record by entity and slug.

  Returns the record if found, nil otherwise.

  ## Examples

      iex> PhoenixKitEntities.EntityData.get_by_slug(entity_uuid, "acme-corporation")
      %PhoenixKitEntities.EntityData{}

      iex> PhoenixKitEntities.EntityData.get_by_slug(entity_uuid, "invalid")
      nil
  """
  @spec get_by_slug(binary(), String.t(), keyword()) :: t() | nil
  def get_by_slug(entity_uuid, slug, opts \\ [])
      when is_binary(entity_uuid) and is_binary(slug) do
    case repo().get_by(__MODULE__, entity_uuid: entity_uuid, slug: slug) do
      nil -> nil
      record -> record |> repo().preload([:entity, :creator]) |> maybe_resolve_lang(opts)
    end
  end

  @doc """
  Checks if a secondary language slug exists for another record within the same entity.

  Queries the JSONB `data` column for `data->lang_code->>'_slug'` matches.
  Used for uniqueness checks on translated slugs.
  """
  @spec secondary_slug_exists?(binary(), String.t(), String.t(), binary() | nil) :: boolean()
  def secondary_slug_exists?(entity_uuid, lang_code, slug, exclude_record_uuid)
      when is_binary(entity_uuid) do
    query =
      from(ed in __MODULE__,
        where: fragment("(? -> ? ->> '_slug') = ?", ed.data, ^lang_code, ^slug),
        where: ed.entity_uuid == ^entity_uuid,
        select: ed.uuid
      )

    query =
      if exclude_record_uuid do
        from(ed in query, where: ed.uuid != ^exclude_record_uuid)
      else
        query
      end

    repo().exists?(query)
  end

  @doc """
  Creates an entity data record.

  ## Examples

      iex> PhoenixKitEntities.EntityData.create(%{entity_uuid: entity_uuid, title: "Test"})
      {:ok, %PhoenixKitEntities.EntityData{}}

      iex> PhoenixKitEntities.EntityData.create(%{title: ""})
      {:error, %Ecto.Changeset{}}

  Note: `created_by` is auto-filled with the first admin or user ID if not provided,
  but only if at least one user exists in the system. If no users exist, the changeset
  will fail with a validation error on `created_by`.
  """
  @spec create(map(), keyword()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs \\ %{}, opts \\ []) do
    # Transaction ensures next_position read + insert are atomic
    repo().transaction(fn ->
      attrs =
        attrs
        |> maybe_add_created_by()
        |> maybe_add_position()

      case %__MODULE__{} |> changeset(attrs) |> repo().insert() do
        {:ok, record} -> record
        {:error, changeset} -> repo().rollback(changeset)
      end
    end)
    |> notify_data_event(:created, opts)
  end

  # Auto-fill created_by_uuid with the first admin when the caller did not name
  # one — with one deliberate exception.
  #
  # An explicit `created_by_uuid: nil` is not "I forgot", it is "this row has no
  # author": the public entity form is unauthenticated by design and passes
  # exactly that. Honouring it stores NULL, which is what the column means from
  # core V169 on. Before V169 the column is NOT NULL and honouring it raises a
  # Postgrex 23502 out of an unauthenticated controller
  # (BeamLabEU/phoenix_kit#706), so on those installs the auto-fill still runs —
  # a submission attributed to the first admin beats one that cannot be saved.
  #
  # A key that is absent entirely keeps the documented convenience either way.
  defp maybe_add_created_by(attrs) when is_map(attrs) do
    supplied = Map.get(attrs, :created_by_uuid) || Map.get(attrs, "created_by_uuid")

    key_present? =
      Map.has_key?(attrs, :created_by_uuid) or Map.has_key?(attrs, "created_by_uuid")

    cond do
      # A blank string is what an untouched form field posts, and `cast/3` turns
      # it into nil — so treating it as a supplied creator would skip the
      # auto-fill and then insert nothing.
      not blank?(supplied) -> attrs
      key_present? and anonymous_creator_supported?() -> attrs
      true -> fill_created_by(attrs)
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp fill_created_by(attrs) do
    case Auth.get_first_admin_uuid() || Auth.get_first_user_uuid() do
      nil -> attrs
      creator_uuid -> Map.put(attrs, created_by_key(attrs), creator_uuid)
    end
  end

  # Core V169 is what makes `phoenix_kit_entity_data.created_by_uuid` nullable.
  # This module pins core from Hex, so it runs against installs on both sides of
  # that line and has to ask the DATABASE, not the compiled dependency.
  #
  # The constant must track the real migration number: nothing reserves one, so
  # a version renumbered before merge would leave this pointing at a different
  # migration entirely. Delete the gate once the core floor is past it.
  @anonymous_creator_version 169
  @anonymous_creator_cache_key {__MODULE__, :anonymous_creator_supported?}

  # ONLY the positive answer is cached. A node that boots while the database is
  # still pre-V169 — the ordinary case, since an app starts before its release
  # task migrates — would otherwise cache `false` into a term with no TTL and no
  # invalidation, and keep attributing anonymous submissions to an administrator
  # until someone restarted the BEAM. Migrations do not run backwards, so a
  # `true` can be cached forever, while a `false` is only ever "not yet".
  defp anonymous_creator_supported? do
    if :persistent_term.get(@anonymous_creator_cache_key, false) do
      true
    else
      # `Migration.migrated_version/0` only works inside a migration runner;
      # `migrated_version_runtime/1` is core's runtime accessor — the same one
      # `phoenix_kit.status` uses. Pass the configured prefix: a `--prefix`
      # install keeps its chain marker in that schema, not in `public`.
      opts = [prefix: Application.get_env(:phoenix_kit, :prefix, "public")]
      supported? = PostgresMigrations.migrated_version_runtime(opts) >= @anonymous_creator_version

      if supported?, do: :persistent_term.put(@anonymous_creator_cache_key, true)
      supported?
    end
  rescue
    # Cannot tell -> fill a creator. An attributed submission is a smaller
    # failure than one that cannot be saved at all.
    _ -> false
  catch
    # An unreachable database RAISES on an unowned checkout but EXITS on a dead
    # pool, so rescue alone would let a public request crash here.
    _, _ -> false
  end

  # Overwrite the caller's own key form when one is already there. Choosing by
  # `:entity_uuid` alone would answer `"created_by_uuid"` for a map that holds an
  # explicit `created_by_uuid: nil` under the atom key, leaving the nil in place
  # beside a filled string key — and Ecto refuses a map mixing key types.
  defp created_by_key(attrs), do: attr_key(attrs, :created_by_uuid, "created_by_uuid")

  defp attr_key(attrs, atom_key, string_key) do
    cond do
      Map.has_key?(attrs, atom_key) -> atom_key
      Map.has_key?(attrs, string_key) -> string_key
      Enum.any?(Map.keys(attrs), &is_binary/1) -> string_key
      true -> atom_key
    end
  end

  # Auto-fill position with next value for the entity if not provided
  defp maybe_add_position(attrs) when is_map(attrs) do
    # Same explicit-nil-vs-absent distinction as `maybe_add_created_by/1` above:
    # a caller passing `position: nil` means "I have no position", not "position
    # is already decided". `position` is nullable, so this stored a NULL rather
    # than raising — the row simply fell out of the entity's ordering instead.
    has_position = not is_nil(Map.get(attrs, :position) || Map.get(attrs, "position"))

    entity_uuid = Map.get(attrs, :entity_uuid) || Map.get(attrs, "entity_uuid")

    if has_position or is_nil(entity_uuid) do
      attrs
    else
      next_pos = next_position(entity_uuid)
      Map.put(attrs, attr_key(attrs, :position, "position"), next_pos)
    end
  end

  @doc """
  Gets the next available position for an entity's data records.

  ## Examples

      iex> next_position(entity_uuid)
      6
  """
  @spec next_position(binary()) :: non_neg_integer()
  def next_position(entity_uuid) when is_binary(entity_uuid) do
    # FOR UPDATE locks matching rows within a transaction to prevent
    # concurrent creates from reading the same max position.
    # NOTE: The lock only takes effect inside a repo().transaction/1 block.
    # Called internally by create/1 which wraps in a transaction.
    # Fetch individual positions with row-level lock, then compute max in Elixir.
    # PostgreSQL does not allow FOR UPDATE with aggregate functions.
    positions =
      from(d in __MODULE__,
        where: d.entity_uuid == ^entity_uuid,
        select: d.position,
        lock: "FOR UPDATE"
      )
      |> repo().all()

    Enum.max(positions, fn -> 0 end) + 1
  end

  @doc """
  Updates the position of a single entity data record.

  ## Examples

      iex> update_position(record, 3)
      {:ok, %EntityData{position: 3}}
  """
  @spec update_position(t(), integer()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update_position(%__MODULE__{} = entity_data, position) when is_integer(position) do
    __MODULE__.update(entity_data, %{position: position})
  end

  # Cap on the number of UUIDs accepted by a single reorder/bulk
  # call. Reorder is a per-page operation; even the largest realistic
  # entity won't have 1000 records visible at once. Beyond this we'd
  # expect an explicit batched API instead of an unbounded transaction.
  @reorder_max_uuids 1000

  @doc """
  Bulk updates positions for multiple records.

  Accepts a list of `{uuid, position}` tuples. Each record is updated
  individually to trigger events and maintain consistency.

  ## Options

    * `:entity_uuid` — when provided, the WHERE clause also filters on
      `entity_uuid`, so a stray UUID from another entity in the input
      list cannot have its position rewritten by the wrong scope. The
      LV reorder paths always pass this; programmatic callers should
      too unless they really intend cross-entity rewrites.

  Returns `{:error, :too_many_uuids}` if more than `#{1000}` pairs are
  supplied — the cap protects the transaction from N+1 unbounded
  `update_all` work and from a malformed LV payload turning into a
  long-running write storm.

  ## Examples

      iex> bulk_update_positions([{"uuid1", 1}, {"uuid2", 2}, {"uuid3", 3}], entity_uuid: e_uuid)
      :ok
  """
  @spec bulk_update_positions([{binary(), integer()}], keyword()) ::
          :ok | {:error, :too_many_uuids | term()}
  def bulk_update_positions(uuid_position_pairs, opts \\ [])

  def bulk_update_positions(uuid_position_pairs, opts)
      when is_list(uuid_position_pairs) and length(uuid_position_pairs) > @reorder_max_uuids do
    log_data_reorder_rejected(:too_many_uuids, length(uuid_position_pairs), opts)
    {:error, :too_many_uuids}
  end

  def bulk_update_positions(uuid_position_pairs, opts)
      when is_list(uuid_position_pairs) do
    entity_uuid_scope = Keyword.get(opts, :entity_uuid)

    # Dedup defensively — a stale DOM may send the same UUID twice
    # (e.g. a quick double-drop). We keep the *last* occurrence so the
    # most recent intended position wins; same outcome the DB would
    # produce, just without the wasted writes.
    pairs =
      uuid_position_pairs
      |> Enum.reverse()
      |> Enum.uniq_by(fn {uuid, _} -> uuid end)
      |> Enum.reverse()

    result =
      repo().transaction(fn ->
        now = UtilsDate.utc_now()

        # Counts the rows actually written, not the pairs submitted. A pair
        # naming a row in another entity updates nothing (that is what the
        # scope is for) and a concurrently deleted row updates nothing
        # either, so "how many did you send" is not "how many moved".
        Enum.reduce(pairs, 0, fn {uuid, position}, written ->
          {count, _} =
            uuid
            |> position_update_query(entity_uuid_scope)
            |> repo().update_all(set: [position: position, date_updated: now])

          written + count
        end)
      end)

    case result do
      {:ok, written} ->
        entity_uuid =
          entity_uuid_scope || resolve_entity_uuid_from_pairs(pairs)

        # The SUCCESS path logged nothing, while both the failure and the
        # rejected-payload paths did — so the activity table contained only
        # reorders that went wrong, and an auditor reading it would conclude
        # reordering was rare rather than invisible. The actor was already
        # being threaded here and then dropped.
        #
        # Logged from the DEDUPED pairs and the written count: a stale DOM
        # double-drop sends the same uuid twice, and recording the raw length
        # made the audit row claim more movement than the transaction
        # performed. Nothing written means nothing happened, and an audit
        # trail that records non-events is worth less than one that does not.
        if written > 0, do: log_data_reorder(pairs, written, entity_uuid, opts)
        notify_reorder_event(entity_uuid)
        :ok

      {:error, reason} ->
        # Cover the user-initiated action even when the DB write fails.
        log_data_reorder_error(uuid_position_pairs, entity_uuid_scope, reason, opts)
        {:error, reason}
    end
  end

  @doc """
  Moves a record to a specific position within its entity, shifting other records.

  Records between the old and new positions are shifted up or down by 1 to
  make room. This is the operation that a drag-and-drop UI would call.

  ## Examples

      iex> move_to_position(record, 3)
      :ok
  """
  @spec move_to_position(t(), integer()) :: :ok | {:error, term()}
  def move_to_position(%__MODULE__{} = record, new_position) when is_integer(new_position) do
    entity_uuid = record.entity_uuid

    result =
      repo().transaction(fn ->
        # Re-read position inside transaction to avoid stale data
        current = repo().get!(__MODULE__, record.uuid)
        old_position = current.position

        cond do
          is_nil(old_position) ->
            do_update_position!(current, new_position)

          old_position == new_position ->
            :noop

          true ->
            now = UtilsDate.utc_now()
            shift_neighbors(entity_uuid, current.uuid, old_position, new_position, now)
            do_update_position!(current, new_position)
        end
      end)

    case result do
      {:ok, :noop} ->
        :ok

      {:ok, _} ->
        notify_reorder_event(entity_uuid)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Update position inside a transaction, rolling back on failure
  defp do_update_position!(record, position) do
    case update_position(record, position) do
      {:ok, updated} -> updated
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  defp shift_neighbors(entity_uuid, record_uuid, old_pos, new_pos, now)
       when old_pos < new_pos do
    # Moving down: shift records in (old, new] up by 1
    from(d in __MODULE__,
      where:
        d.entity_uuid == ^entity_uuid and
          d.position > ^old_pos and
          d.position <= ^new_pos and
          d.uuid != ^record_uuid
    )
    |> repo().update_all(inc: [position: -1], set: [date_updated: now])
  end

  defp shift_neighbors(entity_uuid, record_uuid, old_pos, new_pos, now) do
    # Moving up: shift records in [new, old) down by 1
    from(d in __MODULE__,
      where:
        d.entity_uuid == ^entity_uuid and
          d.position >= ^new_pos and
          d.position < ^old_pos and
          d.uuid != ^record_uuid
    )
    |> repo().update_all(inc: [position: 1], set: [date_updated: now])
  end

  @doc """
  Reorders all records for an entity based on a list of UUIDs in the desired order.

  This is the full reorder operation — takes a list of UUIDs representing the
  new order and assigns positions 1, 2, 3, ... accordingly.

  ## Examples

      iex> reorder(entity_uuid, ["uuid3", "uuid1", "uuid2"])
      :ok
  """
  @spec reorder(binary(), [binary()], keyword()) ::
          :ok | {:error, :too_many_uuids | term()}
  def reorder(entity_uuid, ordered_uuids, opts \\ [])
      when is_binary(entity_uuid) and is_list(ordered_uuids) do
    pairs =
      ordered_uuids
      |> Enum.with_index(1)
      |> Enum.map(fn {uuid, pos} -> {uuid, pos} end)

    bulk_update_positions(pairs, Keyword.put(opts, :entity_uuid, entity_uuid))
  end

  @doc """
  Updates an entity data record.

  ## Options

    * `:actor_uuid` — the user performing the update, recorded on the
      activity log entry.
    * `:activity_log` — defaults to `true`; pass `false` to skip logging
      this update's activity entry (the PubSub broadcast and mirror
      export still fire regardless). Intended for high-frequency callers
      like `LiveDataForm`'s autosave, where logging every debounced
      keystroke would flood the activity log.
    * `:require_status` — defaults to `nil` (no check, existing
      behavior unchanged). Pass a list of status strings (e.g.
      `["draft"]`) to guard against a cross-session race: the record is
      re-read by `uuid` under `SELECT ... FOR UPDATE` inside a
      transaction, and the update only proceeds if the record's
      *current, freshly-read* status is in the list. If it isn't,
      returns `{:error, :status_mismatch}` without touching the row,
      the activity log, or PubSub — as if the call never happened. This
      closes the window where a stale in-memory copy (e.g. a second
      browser tab still holding an `:edit` view of a record that a
      first tab has since submitted/published) would otherwise
      overwrite `data` on a record whose status has since moved on.
      When the status does match, the changeset is built against the
      freshly-read row (not the possibly-stale `entity_data` argument),
      so any other field also reflects the latest DB state going in.
      Must be a list — a bare status string (e.g. `require_status:
      "draft"` instead of `require_status: ["draft"]`) raises
      `ArgumentError` immediately rather than reaching a confusing
      `CaseClauseError`.

  ## Examples

      iex> PhoenixKitEntities.EntityData.update(record, %{title: "Updated"})
      {:ok, %PhoenixKitEntities.EntityData{}}

      iex> PhoenixKitEntities.EntityData.update(record, %{title: ""})
      {:error, %Ecto.Changeset{}}

      iex> PhoenixKitEntities.EntityData.update(record, %{title: "Updated"}, require_status: ["draft"])
      {:error, :status_mismatch}
  """
  @spec update(t(), map(), keyword()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t() | :status_mismatch | :locked_key}
  def update(%__MODULE__{} = entity_data, attrs, opts \\ []) do
    case validate_managed_slug(entity_data, attrs, opts) do
      :ok ->
        case Keyword.get(opts, :require_status) do
          nil ->
            entity_data
            |> changeset(attrs)
            |> repo().update()
            |> notify_data_event(:updated, opts)

          statuses when is_list(statuses) ->
            update_with_status_guard(entity_data, attrs, statuses, opts)

          status when is_binary(status) ->
            raise ArgumentError,
                  "require_status expects a list of statuses, got a binary " <>
                    "(#{inspect(status)}) — wrap it in a list, e.g. require_status: [#{inspect(status)}]"
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A managed blueprint's owner keys its own relations on a value record's
  # slug (e.g. the catalogue's `selected_value_slugs`). `client_writable_params/2`
  # (data_form.ex) does a `Map.take/2` — it keeps `"slug"` only when the
  # incoming params already carry it, not unconditionally — but the admin
  # data form's own template always posts that key (an enabled input, or a
  # disabled field's hidden mirror), so a save from THAT form reaches this
  # function with the key present every time, same as a `Mirror.Importer`
  # save. Not every caller does, though:
  # `components/live_data_form.ex`'s embedded record editor saves only
  # `%{"data" => ...}`, no slug key at all, and takes the skip-on-absence
  # path below instead. Either way, skipping the owning-entity lookup on
  # absence alone isn't where most of the saving here comes from anyway.
  # What actually saves the common case is `Managed.data_mutation_needs_owner?/2`:
  # an ordinary save that resubmits the record's own unchanged values (the
  # common case — a disabled field's hidden mirror, or a title-only edit
  # that round-trips the current values) is cheap to detect without ever
  # reading the owning entity, since `validate_data_mutation/4` would
  # return `:ok` for it regardless of whether the blueprint turns out to
  # be managed. Only an ACTUAL guarded-field change pays for the
  # `Entities.get_entity/1` lookup (a `SELECT` plus `preload(:creator)`).
  # Which fields are guarded, and the `on_behalf_of` bypass, are policy —
  # that lives entirely in `Managed`, not here; see its moduledoc on UI
  # guards without a write interceptor.
  defp validate_managed_slug(entity_data, attrs, opts) do
    if Managed.data_mutation_needs_owner?(entity_data, attrs) do
      owning_entity = Entities.get_entity(entity_data.entity_uuid)
      Managed.validate_data_mutation(owning_entity, entity_data, attrs, opts)
    else
      :ok
    end
  end

  # Re-reads the row by uuid under `FOR UPDATE` inside a transaction so
  # the status check and the write are atomic w.r.t. any concurrent
  # writer — without the lock, two processes could both read a matching
  # status and both proceed, racing the same way this guard exists to
  # prevent. Builds the changeset against the freshly-read row (`fresh`),
  # never the possibly-stale `entity_data` argument, so every field goes
  # into `repo().update/1` reflecting the latest DB state, not just
  # `:data`. A status mismatch (or the row having disappeared entirely —
  # same practical outcome, nothing left to guard) rolls back with no
  # side effects: no write, no activity log, no PubSub broadcast.
  defp update_with_status_guard(entity_data, attrs, statuses, opts) do
    txn =
      repo().transaction(fn ->
        from(d in __MODULE__, where: d.uuid == ^entity_data.uuid, lock: "FOR UPDATE")
        |> repo().one()
        |> apply_status_guarded_update(statuses, attrs)
      end)

    case txn do
      {:ok, updated} ->
        notify_data_event({:ok, updated}, :updated, opts)

      {:error, :status_mismatch} ->
        {:error, :status_mismatch}

      {:error, {:changeset_error, changeset}} ->
        notify_data_event({:error, changeset}, :updated, opts)
    end
  end

  # `nil` covers the row having disappeared entirely between the caller
  # loading it and this re-read — same practical outcome as a status
  # mismatch (nothing left to guard), so it rolls back the same way.
  defp apply_status_guarded_update(nil, _statuses, _attrs), do: repo().rollback(:status_mismatch)

  defp apply_status_guarded_update(%__MODULE__{} = fresh, statuses, attrs) do
    if fresh.status in statuses do
      case fresh |> changeset(attrs) |> repo().update() do
        {:ok, updated} -> updated
        {:error, changeset} -> repo().rollback({:changeset_error, changeset})
      end
    else
      repo().rollback(:status_mismatch)
    end
  end

  @doc """
  Hard-deletes an entity data record.

  Prefer `trash/2` for soft-delete — it keeps the row alive so parent-app
  FK references stay valid. Use this only when the record is genuinely
  unreferenced (e.g. emptying the trash bin).

  Catches `Postgrex.Error` for FK / NOT NULL violations and returns
  `{:error, :referenced_by_external}` so the admin UI can render a friendly
  flash instead of a 500. The row stays in the DB on this error.

  ## Examples

      iex> PhoenixKitEntities.EntityData.delete(record)
      {:ok, %PhoenixKitEntities.EntityData{}}

      iex> # parent_app.orders has a NOT NULL FK to this row
      iex> PhoenixKitEntities.EntityData.delete(record)
      {:error, :referenced_by_external}
  """
  @spec delete(t(), keyword()) ::
          {:ok, t()}
          | {:error, Ecto.Changeset.t() | :referenced_by_external | :has_children}
  def delete(%__MODULE__{} = entity_data, opts \\ []) do
    # Fold the child check INSIDE the transaction so a concurrent
    # insert can't slip a live child between the check and the delete
    # (which would otherwise trip the DB-level FK and surface as
    # `:referenced_by_external` instead of the more accurate
    # `:has_children`).
    txn =
      repo().transaction(fn ->
        if has_live_children?(entity_data.uuid) do
          repo().rollback(:has_children)
        end

        # Null any trashed children's parent_uuid first so the DB-level
        # self-FK doesn't block the parent's delete.
        nullify_trashed_children([entity_data.uuid])

        case repo().delete(entity_data) do
          {:ok, deleted} -> deleted
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case txn do
      {:ok, deleted} ->
        notify_data_event({:ok, deleted}, :deleted, opts)

      {:error, :has_children} ->
        log_data_error_activity(:deleted, opts)
        {:error, :has_children}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  rescue
    # Ecto wraps Postgrex FK violations on Repo.delete in
    # `Ecto.ConstraintError` because `delete/1` doesn't go through a
    # changeset with declared constraints.
    e in Ecto.ConstraintError ->
      if e.type == :foreign_key do
        log_data_error_activity(:deleted, opts)
        {:error, :referenced_by_external}
      else
        reraise e, __STACKTRACE__
      end

    e in Postgrex.Error ->
      if foreign_key_or_not_null_violation?(e) do
        log_data_error_activity(:deleted, opts)
        {:error, :referenced_by_external}
      else
        reraise e, __STACKTRACE__
      end
  end

  defp nullify_trashed_children(parent_uuids) when is_list(parent_uuids) do
    from(d in __MODULE__,
      where: d.parent_uuid in ^parent_uuids and d.status == ^@soft_delete_status
    )
    |> repo().update_all(set: [parent_uuid: nil])
  end

  # "Live" children = non-trashed rows whose parent_uuid points at this
  # record. Trashed children don't block hard-delete: their row stays
  # alive in the DB only to keep parent-app FKs resolving — for
  # entity-internal tree integrity they're invisible.
  defp has_live_children?(uuid) when is_binary(uuid) do
    from(d in __MODULE__,
      where: d.parent_uuid == ^uuid and d.status != ^@soft_delete_status,
      select: 1,
      limit: 1
    )
    |> repo().one()
    |> Kernel.!=(nil)
  end

  @doc """
  Soft-deletes an entity data record by setting its status to `"trashed"`.

  The row remains in the database so any parent-app FK references stay
  valid — historical orders, audit logs, etc. continue to resolve. The
  record is hidden from default `list_*` queries; use `list_trashed_by_entity/2`
  to surface it for the admin trash view.

  Logs `entity_data.trashed` activity. Refuses with `{:error, :already_trashed}`
  if the record is already trashed.

  ## Examples

      iex> EntityData.trash(record, actor_uuid: admin.uuid)
      {:ok, %EntityData{status: "trashed"}}
  """
  @spec trash(t(), keyword()) :: {:ok, t()} | {:error, :already_trashed | Ecto.Changeset.t()}
  def trash(%__MODULE__{status: @soft_delete_status}, _opts), do: {:error, :already_trashed}

  def trash(%__MODULE__{} = entity_data, opts) when is_list(opts) do
    # Stash the row's current status in metadata so restore can return
    # to it. Without this, restore unconditionally lands on "published"
    # and a trashed draft silently goes live on restore.
    metadata =
      (entity_data.metadata || %{})
      |> Map.put("trashed_from_status", entity_data.status)

    entity_data
    |> status_only_changeset(@soft_delete_status, metadata)
    |> repo().update()
    |> notify_data_event(:trashed, opts)
  end

  def trash(%__MODULE__{} = entity_data), do: trash(entity_data, [])

  @doc """
  Restores a trashed entity data record. The status it returns to is
  the one stashed in `metadata["trashed_from_status"]` when the row was
  trashed — defaulting to `"draft"` if no stash is present (e.g. for
  rows trashed via `bulk_trash/2`, or rows trashed before this stash
  shipped).

  Returns `{:error, :not_trashed}` if the record isn't currently trashed —
  guardrail against re-publishing arbitrary records via the trash-restore
  path. Use `update/2` for general status changes.

  ## Examples

      iex> EntityData.restore_from_trash(trashed_record, actor_uuid: admin.uuid)
      {:ok, %EntityData{status: "published"}}  # was published before trashing
  """
  @spec restore_from_trash(t(), keyword()) ::
          {:ok, t()} | {:error, :not_trashed | Ecto.Changeset.t()}
  def restore_from_trash(entity_data, opts \\ [])

  def restore_from_trash(%__MODULE__{status: @soft_delete_status} = entity_data, opts) do
    prior_status =
      case entity_data.metadata do
        %{"trashed_from_status" => s} when s in @valid_statuses and s != @soft_delete_status -> s
        _ -> "draft"
      end

    metadata = (entity_data.metadata || %{}) |> Map.delete("trashed_from_status")

    entity_data
    |> status_only_changeset(prior_status, metadata)
    |> repo().update()
    |> notify_data_event(:restored, opts)
  end

  def restore_from_trash(%__MODULE__{}, _opts), do: {:error, :not_trashed}

  # Focused changeset for trash / restore — only touches `:status`,
  # `:metadata`, and `:date_updated`. Skips the full per-field validation
  # against the entity blueprint because a record whose `:data` is no
  # longer valid (e.g. the entity gained a required field after the row
  # was created) must still be retirable via trash. The bulk paths
  # bypass changesets entirely; this keeps single-record + bulk in sync.
  defp status_only_changeset(entity_data, status, metadata) do
    entity_data
    |> cast(%{status: status, metadata: metadata, date_updated: UtilsDate.utc_now()}, [
      :status,
      :metadata,
      :date_updated
    ])
    |> validate_inclusion(:status, @valid_statuses)
  end

  # Match Postgres FK / NOT NULL violations raised when a parent-app row
  # still references this record. SQLSTATE codes are stable: `23503` =
  # foreign_key_violation (default NO ACTION), `23502` = not_null_violation,
  # `23001` = restrict_violation (explicit `ON DELETE RESTRICT`, which
  # Postgres reports under its own code rather than 23503). Any other
  # error is re-raised so real bugs still surface.
  defp foreign_key_or_not_null_violation?(%Postgrex.Error{postgres: %{code: code}})
       when code in [:foreign_key_violation, :not_null_violation, :restrict_violation],
       do: true

  defp foreign_key_or_not_null_violation?(%Postgrex.Error{postgres: %{code: code}})
       when is_binary(code) and code in ["23503", "23502", "23001"],
       do: true

  defp foreign_key_or_not_null_violation?(_), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking entity data changes.

  ## Examples

      iex> PhoenixKitEntities.EntityData.change(record)
      %Ecto.Changeset{data: %PhoenixKitEntities.EntityData{}}
  """
  @spec change(t(), map()) :: Ecto.Changeset.t()
  def change(%__MODULE__{} = entity_data, attrs \\ %{}) do
    changeset(entity_data, attrs)
  end

  @doc """
  Searches entity data records by title.

  ## Examples

      iex> PhoenixKitEntities.EntityData.search_by_title("Acme")
      [%PhoenixKitEntities.EntityData{}, ...]

      iex> PhoenixKitEntities.EntityData.search_by_title("Acme", entity_uuid)
      [%PhoenixKitEntities.EntityData{}, ...]

      iex> PhoenixKitEntities.EntityData.search_by_title("Acme", entity_uuid, lang: "es")
      [%PhoenixKitEntities.EntityData{}, ...]
  """
  @spec search_by_title(String.t()) :: [t()]
  @spec search_by_title(String.t(), binary() | nil, keyword()) :: [t()]
  def search_by_title(search_term) when is_binary(search_term),
    do: search_by_title(search_term, nil, [])

  def search_by_title(search_term, entity_uuid, opts \\ [])

  def search_by_title(search_term, entity_uuid, opts)
      when is_binary(search_term) do
    # Escaped: `escape_like/1` exists in this module and is applied by
    # `entity_uuids_matching_title/3`, but not here — so an admin searching
    # "50%" matched every record, and "a_b" matched "axb". Not injection
    # (Ecto parameterises), but a wrong answer and an unbounded scan.
    search_pattern = "%#{escape_like(search_term)}%"
    order = if entity_uuid, do: resolve_sort_order(entity_uuid, opts), else: [desc: :date_created]

    query =
      from(d in __MODULE__,
        where: ilike(d.title, ^search_pattern),
        order_by: ^order,
        preload: [:entity, :creator]
      )

    query =
      case entity_uuid do
        nil ->
          query

        uuid when is_binary(uuid) ->
          from(d in query, where: d.entity_uuid == ^uuid)
      end

    query
    |> exclude_trashed(opts)
    |> repo().all()
    |> maybe_resolve_langs(opts)
  end

  @doc """
  Gets all published records for a specific entity.

  ## Examples

      iex> PhoenixKitEntities.EntityData.published_records(entity_uuid)
      [%PhoenixKitEntities.EntityData{status: "published"}, ...]
  """
  @spec published_records(binary(), keyword()) :: [t()]
  def published_records(entity_uuid, opts \\ []) when is_binary(entity_uuid) do
    list_by_entity_and_status(entity_uuid, "published", opts)
  end

  @doc """
  Counts records for an entity.

  Excludes trashed records by default. Pass `include_trashed: true` to
  count everything.

  ## Examples

      iex> PhoenixKitEntities.EntityData.count_by_entity(entity_uuid)
      42

      iex> PhoenixKitEntities.EntityData.count_by_entity(entity_uuid, include_trashed: true)
      45
  """
  @spec count_by_entity(binary(), keyword()) :: non_neg_integer()
  def count_by_entity(entity_uuid, opts \\ []) when is_binary(entity_uuid) do
    from(d in __MODULE__, where: d.entity_uuid == ^entity_uuid, select: count(d.uuid))
    |> exclude_trashed(opts)
    |> repo().one()
  end

  @doc """
  Record counts for many entities at once: `%{entity_uuid => count}`.
  One grouped query — a listing showing counts for a page of entities
  must not run one COUNT per row (and must never length/1 a full load).
  `exclude_statuses:` drops records in the given statuses from the tally
  (e.g. `["archived"]` to match viewers that hide archived records);
  trashed records are excluded the same way `list_by_entity/2` does it.
  """
  @spec counts_by_entities([binary()], keyword()) :: %{optional(binary()) => non_neg_integer()}
  def counts_by_entities(entity_uuids, opts \\ [])
  def counts_by_entities([], _opts), do: %{}

  def counts_by_entities(entity_uuids, opts) when is_list(entity_uuids) do
    query =
      from(d in __MODULE__,
        where: d.entity_uuid in ^entity_uuids,
        group_by: d.entity_uuid,
        select: {d.entity_uuid, count(d.uuid)}
      )
      |> exclude_trashed(opts)

    query =
      case opts[:exclude_statuses] do
        statuses when is_list(statuses) and statuses != [] ->
          from(d in query, where: d.status not in ^statuses)

        _ ->
          query
      end

    query |> repo().all() |> Map.new()
  end

  @doc """
  Of the given entities, which have at least one record whose title
  matches `term`? Returns a deduplicated list of entity uuids.

  One DISTINCT query for the whole batch — a listing that filters its
  rows by "does this entity contain a matching record?" must not run a
  search per row, and must never load the records themselves just to
  test for existence. Trashed records are excluded the same way
  `list_by_entity/2` does it; `exclude_statuses:` drops more (e.g.
  `["archived"]` to match viewers that hide archived records).

  A blank term matches nothing — callers treat "no query" as "no
  filter" and should not call this at all. A LIST, not a MapSet:
  the result crosses a module boundary (the catalogue calls this
  through `apply/3` under its released pin) and MapSet is opaque, so
  callers build their own set.

  ## Examples

      iex> PhoenixKitEntities.EntityData.entity_uuids_matching_title(uuids, "oak")
      ["01a0…"]
  """
  @spec entity_uuids_matching_title([binary()], String.t(), keyword()) :: [binary()]
  def entity_uuids_matching_title(entity_uuids, term, opts \\ [])
  def entity_uuids_matching_title([], _term, _opts), do: []

  def entity_uuids_matching_title(entity_uuids, term, opts)
      when is_list(entity_uuids) and is_binary(term) do
    case String.trim(term) do
      "" ->
        []

      trimmed ->
        pattern = "%#{escape_like(trimmed)}%"

        query =
          from(d in __MODULE__,
            where: d.entity_uuid in ^entity_uuids,
            # The data JSONB alongside the title column: translations
            # live there under language keys, so a record titled "Oak" in
            # en and "Tamm" in et is found by either. Only string VALUES
            # are searched — reading the encoded document matched KEY
            # names too, so a query of "a" hit anything holding `_title`
            # (Max, 2026-08-28).
            where:
              ilike(d.title, ^pattern) or
                fragment(
                  "EXISTS (SELECT 1 FROM jsonb_path_query(?, '$.**') AS v WHERE jsonb_typeof(v) = 'string' AND v #>> '{}' ILIKE ?)",
                  d.data,
                  ^pattern
                ),
            distinct: true,
            select: d.entity_uuid
          )
          |> exclude_trashed(opts)

        query =
          case opts[:exclude_statuses] do
            statuses when is_list(statuses) and statuses != [] ->
              from(d in query, where: d.status not in ^statuses)

            _ ->
              query
          end

        repo().all(query)
    end
  end

  # `%`, `_` and `\\` are LIKE metacharacters — a value titled "50%" must
  # not turn the pattern into a wildcard.
  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  Counts trashed records for an entity. Drives the trash-bin badge.
  """
  @spec trashed_count(binary()) :: non_neg_integer()
  def trashed_count(entity_uuid) when is_binary(entity_uuid) do
    from(d in __MODULE__,
      where: d.entity_uuid == ^entity_uuid and d.status == ^@soft_delete_status,
      select: count(d.uuid)
    )
    |> repo().one()
  end

  @doc """
  Gets records filtered by status across all entities.

  When `status` is `"trashed"`, returns trashed records. For all other
  statuses, the query is implicitly scoped (status filter excludes trashed
  by virtue of matching a different status).

  ## Examples

      iex> PhoenixKitEntities.EntityData.filter_by_status("draft")
      [%PhoenixKitEntities.EntityData{status: "draft"}, ...]
  """
  @spec filter_by_status(String.t(), keyword()) :: [t()]
  def filter_by_status(status, opts \\ []) when status in @valid_statuses do
    from(d in __MODULE__,
      where: d.status == ^status,
      order_by: [desc: d.date_created],
      preload: [:entity, :creator]
    )
    |> repo().all()
    |> maybe_resolve_langs(opts)
  end

  @doc """
  Returns a public path for a record, respecting locale and the configured URL pattern.

  URL pattern resolution chain (shared with `PhoenixKitEntities.SitemapSource`):
  1. `entity.settings["sitemap_url_pattern"]`
  2. Router introspection (via `PhoenixKit.Modules.Sitemap.RouteResolver`)
  3. Per-entity setting `sitemap_entity_<name>_pattern`
  4. Global pattern setting `sitemap_entities_pattern`
  5. Fallback `/<entity_name>/:slug`

  Locale prefix policy (matches `PhoenixKit.Utils.Routes.path/2`):
  - `:locale` omitted or `nil` → no prefix
  - Single-language mode → no prefix
  - Primary language → follows the site-wide `default_language_no_prefix`
    setting: prefixed by default (setting OFF), unprefixed when ON
  - Other locales → prefixed with the base code (`/es/...`, `/ru/...`)

  Slug resolution:
  - When `:locale` is given and the record has a secondary-language slug
    override stored as `data[locale]["_slug"]`, that override is substituted
    for `:slug` in the pattern. Otherwise the primary `record.slug` is used
    (falling back to the UUID when slug is nil).

  ## Options

    * `:locale` — locale code (dialect like `"es-ES"` or base `"es"`). Omit to skip prefixing.
    * `:routes_cache` — pre-built cache from `UrlResolver.build_routes_cache/0` (for batches).

  ## Examples

      iex> EntityData.public_path(entity, record)
      "/products/my-item"

      iex> EntityData.public_path(entity, record, locale: "es-ES")
      "/es/products/my-item"

      iex> EntityData.public_path(entity, record, locale: "en-US")  # primary, default_language_no_prefix OFF (default)
      "/en/products/my-item"
  """
  @spec public_path(map(), map(), keyword()) :: String.t()
  def public_path(entity, record, opts \\ []) do
    locale = Keyword.get(opts, :locale)
    cache = Keyword.get(opts, :routes_cache) || UrlResolver.build_routes_cache()

    pattern = UrlResolver.get_url_pattern_cached(entity, cache) || "/#{entity.name}/:slug"
    localized_record = maybe_apply_translated_slug(record, locale)
    path = UrlResolver.build_path(pattern, localized_record)

    UrlResolver.add_public_locale_prefix(path, locale)
  end

  # If the record carries a secondary-language `_slug` override for the
  # requested locale, swap it onto the record before placeholder substitution.
  # Keeps the URL stable in the primary language and lets `/es/products/mi-item`
  # use `mi-item` instead of the English slug.
  defp maybe_apply_translated_slug(record, nil), do: record
  defp maybe_apply_translated_slug(record, ""), do: record

  defp maybe_apply_translated_slug(record, locale) when is_binary(locale) do
    case translated_slug(record, locale) do
      nil -> record
      translated -> Map.put(record, :slug, translated)
    end
  end

  defp translated_slug(%{data: data}, locale) when is_map(data) do
    case get_in(data, [locale, "_slug"]) do
      slug when is_binary(slug) and slug != "" -> slug
      _ -> nil
    end
  end

  defp translated_slug(_record, _locale), do: nil

  @doc """
  Returns a full public URL for a record by prepending a base URL to `public_path/3`.

  ## Options

    * `:base_url` — explicit base (e.g. `"https://site.com"`). Falls back to the
      `site_url` setting, then an empty string.
    * `:locale` — forwarded to `public_path/3`.
    * `:routes_cache` — forwarded to `public_path/3`.

  ## Examples

      iex> EntityData.public_url(entity, record, base_url: "https://shop.example.com")
      "https://shop.example.com/products/my-item"
  """
  @spec public_url(map(), map(), keyword()) :: String.t()
  def public_url(entity, record, opts \\ []) do
    path = public_path(entity, record, opts)
    base_url = Keyword.get(opts, :base_url)

    UrlResolver.build_url(path, base_url)
  end

  @doc """
  Returns hreflang alternates and a canonical URL for a record across all
  enabled languages.

  When the same record serves at both the unprefixed primary-language URL
  (`/products/my-item`) and a per-locale prefixed URL (`/es/products/mi-item`),
  search engines can index both as duplicate content. Use this helper to emit
  `<link rel="alternate" hreflang="...">` and `<link rel="canonical">` tags
  alongside `public_path/3` so the duplication is declared rather than
  competing.

  ## Output shape

      %{
        canonical: "https://site.com/en/products/my-item",
        alternates: [
          %{locale: "en", href: "https://site.com/en/products/my-item"},
          %{locale: "es", href: "https://site.com/es/products/mi-item"},
          %{locale: "x-default", href: "https://site.com/en/products/my-item"}
        ]
      }

  The primary-language `canonical`/`href` shape follows the site-wide
  `default_language_no_prefix` setting (prefixed by default, as shown
  above; unprefixed — `/products/my-item` — when the setting is ON).

  Locales are emitted as base codes (`"en"`, `"es"`) — matching the locale
  prefix policy used in `public_path/3` and Google's hreflang docs (which
  recommend `xx` over `xx-XX` unless region targeting is required).

  ## Options

    * `:base_url` — explicit absolute URL prefix (e.g. `"https://shop.example.com"`).
      Falls back to the `site_url` setting, then `""` (which yields path-only
      `href` values — useful in tests but not in production HTML).
    * `:routes_cache` — pre-built cache from `UrlResolver.build_routes_cache/0`
      (avoid rebuilding per call when emitting many records).
    * `:primary_locale` — overrides the locale considered "canonical".
      Defaults to `Multilang.primary_language/0` with rescue fallback to the
      first enabled locale.

  When the Multilang module is unavailable or only one language is enabled,
  the result has a single canonical entry and no `:alternates`.
  """
  @spec public_alternates(map(), map(), keyword()) :: %{
          canonical: String.t(),
          alternates: [%{locale: String.t(), href: String.t()}]
        }
  def public_alternates(entity, record, opts \\ []) do
    cache = Keyword.get(opts, :routes_cache) || UrlResolver.build_routes_cache()
    opts_with_cache = Keyword.put(opts, :routes_cache, cache)

    locales = enabled_locales()
    primary_dialect = Keyword.get(opts, :primary_locale) || safe_primary_language(locales)

    canonical_locale_url =
      public_url(entity, record, Keyword.put(opts_with_cache, :locale, primary_dialect))

    alternates =
      locales
      |> Enum.map(fn dialect ->
        href = public_url(entity, record, Keyword.put(opts_with_cache, :locale, dialect))
        %{locale: locale_base(dialect), href: href}
      end)
      |> Enum.uniq_by(& &1.locale)

    alternates =
      case alternates do
        [_ | _] = list -> list ++ [%{locale: "x-default", href: canonical_locale_url}]
        _ -> []
      end

    %{canonical: canonical_locale_url, alternates: alternates}
  end

  defp enabled_locales do
    Multilang.enabled_languages()
  rescue
    _ -> []
  end

  defp safe_primary_language(fallback_locales) do
    Multilang.primary_language()
  rescue
    _ -> List.first(fallback_locales)
  end

  defp locale_base(dialect) when is_binary(dialect) do
    DialectMapper.extract_base(dialect)
  rescue
    _ -> dialect
  end

  defp locale_base(_), do: nil

  @doc """
  Alias for list_all/1 for consistency with LiveView naming.
  """
  @spec list_all_data(keyword()) :: [t()]
  def list_all_data(opts \\ []), do: list_all(opts)

  @doc """
  Alias for list_by_entity/2 for consistency with LiveView naming.
  """
  @spec list_data_by_entity(binary(), keyword()) :: [t()]
  def list_data_by_entity(entity_uuid, opts \\ []), do: list_by_entity(entity_uuid, opts)

  @doc """
  Alias for filter_by_status/2 for consistency with LiveView naming.
  """
  @spec list_data_by_status(String.t(), keyword()) :: [t()]
  def list_data_by_status(status, opts \\ []), do: filter_by_status(status, opts)

  @doc """
  Alias for search_by_title for consistency with LiveView naming.
  """
  @spec search_data(String.t()) :: [t()]
  @spec search_data(String.t(), binary() | nil, keyword()) :: [t()]
  def search_data(search_term) when is_binary(search_term),
    do: search_by_title(search_term, nil, [])

  def search_data(search_term, entity_uuid, opts \\ []),
    do: search_by_title(search_term, entity_uuid, opts)

  @doc """
  Alias for get!/2 for consistency with LiveView naming.
  """
  @spec get_data!(binary(), keyword()) :: t()
  def get_data!(id, opts \\ []), do: get!(id, opts)

  @doc """
  Alias for delete/1 for consistency with LiveView naming.
  """
  @spec delete_data(t(), keyword()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t() | :referenced_by_external}
  def delete_data(entity_data, opts \\ []), do: __MODULE__.delete(entity_data, opts)

  @doc """
  Counts external (parent-app) rows that reference this record.

  Reads `:reverse_references` from `Application.get_env/2` — a list of
  `{entity_name, count_fn}` tuples where `count_fn` is a 1-arity
  function that takes the entity_data uuid and returns a non-negative
  integer. Returns the total count across all matching callbacks for
  the record's entity, or `0` if no callbacks are registered.

  **Informational only — NOT a delete-blocker.** Soft-delete keeps the
  row alive regardless of how many parent rows reference it; this
  count is just for the admin UI to surface "Used by N rows" hints
  before the operator clicks Trash or Permanently delete. Don't wire
  it into the actual delete path.

  ## Performance — pass `entity` when the caller already has it

  The single-arg form preloads `:entity` on every call. Parent-app
  callers rendering many records in a loop can pass the already-loaded
  entity as the second arg to skip the per-call N+1:

      entity = Entities.get_entity!(entity_uuid)

      Enum.map(records, fn record ->
        EntityData.count_external_references(record, entity)
      end)

  ## Configuration

      # In parent app config:
      config :phoenix_kit_entities,
        reverse_references: [
          {"order_status", &MyApp.Orders.count_orders_with_status/1},
          {"sub_order_status", &MyApp.Orders.count_sub_orders_with_status/1}
        ]

  Multiple callbacks per entity name are supported — every matching
  tuple's count contributes to the total. Useful when the same
  entity_data acts as a controlled vocabulary for several parent
  tables (e.g. `orders` and `audit_log` both referencing
  `order_status`).
  """
  @spec count_external_references(t()) :: non_neg_integer()
  @spec count_external_references(t(), map() | nil) :: non_neg_integer()
  def count_external_references(entity_data, entity \\ nil)

  def count_external_references(%__MODULE__{} = entity_data, %{name: name})
      when is_binary(name) do
    do_count_external_references(entity_data, name)
  end

  def count_external_references(%__MODULE__{} = entity_data, nil) do
    # Fall back to a per-call preload when the caller didn't pass an
    # entity. Always exits to do_count_external_references/2 or to 0 —
    # never re-enters this clause, so the orphan-entity case can't
    # recurse infinitely.
    case repo().preload(entity_data, :entity).entity do
      %{name: name} when is_binary(name) -> do_count_external_references(entity_data, name)
      _ -> 0
    end
  end

  def count_external_references(%__MODULE__{}, _), do: 0

  defp do_count_external_references(entity_data, name) when is_binary(name) do
    :phoenix_kit_entities
    |> Application.get_env(:reverse_references, [])
    |> Enum.filter(fn
      {^name, fun} when is_function(fun, 1) -> true
      _ -> false
    end)
    |> Enum.reduce(0, fn {_name, fun}, acc ->
      try do
        count = fun.(entity_data.uuid)
        if is_integer(count) and count >= 0, do: acc + count, else: acc
      rescue
        # Narrow to the DB-availability shapes — bugs in the parent-app
        # callback (KeyError, FunctionClauseError, etc.) should surface
        # in logs instead of silently zeroing the count. A broken
        # callback that reports "Used by 0 rows" is the surprising
        # default this guard was supposed to prevent.
        e in [DBConnection.ConnectionError, Postgrex.Error] ->
          Logger.warning("[Entities] reverse_references callback failed: #{Exception.message(e)}")

          acc
      end
    end)
  end

  @doc """
  Alias for update/2 for consistency with LiveView naming.
  """
  @spec update_data(t(), map(), keyword()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update_data(entity_data, attrs, opts \\ []),
    do: __MODULE__.update(entity_data, attrs, opts)

  @doc """
  Bulk updates the status of multiple records by UUIDs.

  Returns a tuple with the count of updated records and nil. Logs a
  single `entity_data.bulk_status_changed` activity row carrying the
  count + new status. Per-record `entity_data.updated` rows are NOT
  emitted — bulk operations log at the operation level so the audit
  trail doesn't explode.

  ## Options

    * `:actor_uuid` — UUID of the user performing the bulk update.
      Threaded through to the activity log entry.

  ## Examples

      iex> PhoenixKitEntities.EntityData.bulk_update_status(["uuid1", "uuid2"], "archived",
      ...>   actor_uuid: admin.uuid)
      {2, nil}
  """
  @spec bulk_update_status([String.t()], String.t(), keyword()) :: {non_neg_integer(), nil}
  def bulk_update_status(uuids, status, opts \\ [])
      when is_list(uuids) and status in @valid_statuses do
    now = UtilsDate.utc_now()

    {count, _} =
      result =
      from(d in __MODULE__, where: d.uuid in ^uuids)
      |> repo().update_all(set: [status: status, date_updated: now])

    PhoenixKitEntities.ActivityLog.log(%{
      action: "entity_data.bulk_status_changed",
      mode: "manual",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "entity_data",
      metadata: %{
        "status" => status,
        "count" => count,
        "uuid_count" => length(uuids)
      }
    })

    result
  end

  @doc """
  Bulk hard-deletes records by UUIDs.

  Prefer `bulk_trash/2` for soft-delete. Use this for emptying-the-trash
  flows where the records are confirmed unreferenced.

  Catches `Postgrex.Error` for FK / NOT NULL violations and returns
  `{:error, :referenced_by_external}` so the admin UI can flash a
  friendly message rather than 500. The transaction rolls back on this
  error — no records are deleted.

  ## Options

    * `:actor_uuid` — UUID of the user performing the bulk delete.

  ## Examples

      iex> PhoenixKitEntities.EntityData.bulk_delete(["uuid1", "uuid2"], actor_uuid: admin.uuid)
      {2, nil}

      iex> PhoenixKitEntities.EntityData.bulk_delete([referenced_uuid])
      {:error, :referenced_by_external}
  """
  @spec bulk_delete([String.t()], keyword()) ::
          {non_neg_integer(), nil}
          | {:error, :referenced_by_external | :has_children}
  def bulk_delete(uuids, opts \\ []) when is_list(uuids) do
    # Wrap the activity-log call OUTSIDE the transaction so a logging
    # failure can't be misclassified as `:referenced_by_external`.
    case run_bulk_delete_txn(uuids) do
      {:ok, {count, deleted}} ->
        # Parity with the single-record path (`notify_data_event/3`'s
        # `:deleted` clause): a bulk hard-delete is the ordinary way to
        # remove a value permanently (emptying the trash — see
        # `web/data_navigator.ex`'s "Delete forever"), so the owner's
        # own safety net (a subscriber that prunes dangling slug
        # references) needs the same `:data_deleted` event per row this
        # emits for a single delete. Per-record activity rows are still
        # NOT logged here — only the operation-level row below — same
        # as `bulk_update_status/3` and `bulk_trash/2`.
        Enum.each(deleted, fn {data_uuid, entity_uuid} ->
          Events.broadcast_data_deleted(entity_uuid, data_uuid)
        end)

        PhoenixKitEntities.ActivityLog.log(%{
          action: "entity_data.bulk_deleted",
          mode: "manual",
          actor_uuid: Keyword.get(opts, :actor_uuid),
          resource_type: "entity_data",
          metadata: %{
            "count" => count,
            "uuid_count" => length(uuids)
          }
        })

        {count, nil}

      {:error, :has_children} ->
        log_data_error_activity(:bulk_deleted, opts)
        {:error, :has_children}

      {:error, _} ->
        log_data_error_activity(:bulk_deleted, opts)
        {:error, :referenced_by_external}
    end
  end

  defp run_bulk_delete_txn(uuids) do
    repo().transaction(fn ->
      # Fold the check inside the transaction so a concurrent insert
      # can't land a live external child between the check and the
      # delete.
      if has_external_live_children?(uuids) do
        repo().rollback(:has_children)
      end

      # Null trashed children of any row in the input set before
      # deleting, so the self-FK doesn't block.
      nullify_trashed_children(uuids)

      # `select` gets the deleted rows' uuid/entity_uuid back atomically
      # with the delete — no separate SELECT, no race with a concurrent
      # delete of the same rows between two queries. (`delete_all/2` has
      # no `:returning` option — `select` in the query is how Ecto
      # returns data from a `DELETE`, same as `update_all/3`.)
      from(d in __MODULE__, where: d.uuid in ^uuids, select: {d.uuid, d.entity_uuid})
      |> repo().delete_all()
    end)
  rescue
    e in Postgrex.Error ->
      if foreign_key_or_not_null_violation?(e) do
        {:error, :referenced_by_external}
      else
        reraise e, __STACKTRACE__
      end
  end

  # A child is "external" to the bulk_delete set if its parent is being
  # deleted but the child itself is not. Children that are also in the
  # input list are fine — they get deleted alongside their parent.
  # Trashed children don't block (same rule as the single-record path).
  defp has_external_live_children?([]), do: false

  defp has_external_live_children?(uuids) when is_list(uuids) do
    from(d in __MODULE__,
      where:
        d.parent_uuid in ^uuids and
          d.status != ^@soft_delete_status and
          d.uuid not in ^uuids,
      select: 1,
      limit: 1
    )
    |> repo().one()
    |> Kernel.!=(nil)
  end

  @doc """
  Bulk soft-deletes records by setting their status to `"trashed"`.

  Returns `{count, nil}` for the number of records actually trashed
  (already-trashed records are skipped via the WHERE clause). Logs a
  single `entity_data.bulk_trashed` row.

  ## Examples

      iex> EntityData.bulk_trash(["uuid1", "uuid2"], actor_uuid: admin.uuid)
      {2, nil}
  """
  @spec bulk_trash([String.t()], keyword()) :: {non_neg_integer(), nil}
  def bulk_trash(uuids, opts \\ []) when is_list(uuids) do
    now = UtilsDate.utc_now()

    {count, _} =
      result =
      from(d in __MODULE__,
        where: d.uuid in ^uuids and d.status != ^@soft_delete_status
      )
      |> repo().update_all(set: [status: @soft_delete_status, date_updated: now])

    PhoenixKitEntities.ActivityLog.log(%{
      action: "entity_data.bulk_trashed",
      mode: "manual",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "entity_data",
      metadata: %{"count" => count, "uuid_count" => length(uuids)}
    })

    # Broadcast per affected entity so any LV viewing those records refreshes.
    broadcast_bulk_change(uuids)

    result
  end

  @doc """
  Bulk restores trashed records to `"published"` status.

  Only rows currently `"trashed"` are touched. Logs
  `entity_data.bulk_restored` with the affected count.

  ## Examples

      iex> EntityData.bulk_restore_from_trash(["uuid1", "uuid2"], actor_uuid: admin.uuid)
      {2, nil}
  """
  @spec bulk_restore_from_trash([String.t()], keyword()) :: {non_neg_integer(), nil}
  def bulk_restore_from_trash(uuids, opts \\ []) when is_list(uuids) do
    now = UtilsDate.utc_now()

    {count, _} =
      result =
      from(d in __MODULE__,
        where: d.uuid in ^uuids and d.status == ^@soft_delete_status
      )
      |> repo().update_all(set: [status: "published", date_updated: now])

    PhoenixKitEntities.ActivityLog.log(%{
      action: "entity_data.bulk_restored",
      mode: "manual",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "entity_data",
      metadata: %{"count" => count, "uuid_count" => length(uuids)}
    })

    broadcast_bulk_change(uuids)

    result
  end

  # Look up the entity_uuid for each affected row and broadcast a
  # data_updated event per (entity, record) pair so any open LV refreshes.
  defp broadcast_bulk_change(uuids) when is_list(uuids) do
    from(d in __MODULE__, where: d.uuid in ^uuids, select: {d.entity_uuid, d.uuid})
    |> repo().all()
    |> Enum.each(fn {entity_uuid, uuid} ->
      Events.broadcast_data_updated(entity_uuid, uuid)
    end)
  end

  @doc """
  Gets statistical data about entity data records.

  `total_records` is the count of *non-trashed* records (the visible
  total). `trashed_records` is reported separately so the admin can
  surface the trash-bin badge.

  ## Examples

      iex> PhoenixKitEntities.EntityData.get_data_stats()
      %{
        total_records: 150,
        published_records: 120,
        draft_records: 25,
        archived_records: 5,
        trashed_records: 3
      }
  """
  @spec get_data_stats(binary() | nil) :: %{
          total_records: non_neg_integer(),
          published_records: non_neg_integer(),
          draft_records: non_neg_integer(),
          archived_records: non_neg_integer(),
          trashed_records: non_neg_integer()
        }
  def get_data_stats(entity_uuid \\ nil) do
    query =
      from(d in __MODULE__,
        select: {
          count(fragment("CASE WHEN ? <> 'trashed' THEN 1 END", d.status)),
          count(fragment("CASE WHEN ? = 'published' THEN 1 END", d.status)),
          count(fragment("CASE WHEN ? = 'draft' THEN 1 END", d.status)),
          count(fragment("CASE WHEN ? = 'archived' THEN 1 END", d.status)),
          count(fragment("CASE WHEN ? = 'trashed' THEN 1 END", d.status))
        }
      )

    query =
      case entity_uuid do
        nil ->
          query

        uuid when is_binary(uuid) ->
          from(d in query, where: d.entity_uuid == ^uuid)
      end

    {total, published, draft, archived, trashed} = repo().one(query)

    %{
      total_records: total,
      published_records: published,
      draft_records: draft,
      archived_records: archived,
      trashed_records: trashed
    }
  end

  # ============================================================================
  # Translation convenience API
  # ============================================================================

  @doc """
  Gets the data fields for a specific language, merged with primary language defaults.

  For multilang records, returns `Map.merge(primary_data, language_overrides)`.
  For flat (non-multilang) records, returns the data as-is.

  ## Examples

      iex> get_translation(record, "es-ES")
      %{"name" => "Acme España", "category" => "Tech"}

      iex> get_translation(flat_record, "en-US")
      %{"name" => "Acme", "category" => "Tech"}
  """
  @spec get_translation(t(), String.t()) :: map()
  def get_translation(%__MODULE__{data: data}, lang_code) when is_binary(lang_code) do
    Multilang.get_language_data(data, lang_code)
  end

  @doc """
  Gets the raw (non-merged) data for a specific language.

  For secondary languages, returns only the override fields (not merged with primary).
  Useful for seeing which fields have explicit translations.

  ## Examples

      iex> get_raw_translation(record, "es-ES")
      %{"name" => "Acme España"}
  """
  @spec get_raw_translation(t(), String.t()) :: map()
  def get_raw_translation(%__MODULE__{data: data}, lang_code) when is_binary(lang_code) do
    Multilang.get_raw_language_data(data, lang_code)
  end

  @doc """
  Gets translations for all languages in a record.

  Returns a map of language codes to their merged data.
  For flat records, returns the data under the primary language key.

  ## Examples

      iex> get_all_translations(record)
      %{
        "en-US" => %{"name" => "Acme", "category" => "Tech"},
        "es-ES" => %{"name" => "Acme España", "category" => "Tech"}
      }
  """
  @spec get_all_translations(t()) :: %{optional(String.t()) => map()}
  def get_all_translations(%__MODULE__{data: data}) do
    if Multilang.multilang_data?(data) do
      Multilang.enabled_languages()
      |> Map.new(fn lang -> {lang, Multilang.get_language_data(data, lang)} end)
    else
      primary = Multilang.primary_language()
      %{primary => data || %{}}
    end
  end

  @doc """
  Sets the data translation for a specific language on a record.

  For the primary language, stores all fields.
  For secondary languages, only stores fields that differ from primary (overrides).
  Persists to the database.

  ## Examples

      iex> set_translation(record, "es-ES", %{"name" => "Acme España"})
      {:ok, %EntityData{}}

      iex> set_translation(record, "en-US", %{"name" => "Acme Corp", "category" => "Tech"})
      {:ok, %EntityData{}}
  """
  @spec set_translation(t(), String.t(), map()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def set_translation(%__MODULE__{} = entity_data, lang_code, field_data)
      when is_binary(lang_code) and is_map(field_data) do
    updated_data = Multilang.put_language_data(entity_data.data, lang_code, field_data)
    __MODULE__.update(entity_data, %{data: updated_data})
  end

  @doc """
  Removes all data for a specific language from a record.

  Cannot remove the primary language. Returns `{:error, :cannot_remove_primary}`
  if the primary language is targeted.

  ## Examples

      iex> remove_translation(record, "es-ES")
      {:ok, %EntityData{}}

      iex> remove_translation(record, "en-US")
      {:error, :cannot_remove_primary}
  """
  @spec remove_translation(t(), String.t()) ::
          {:ok, t()}
          | {:error, :cannot_remove_primary | :not_multilang | Ecto.Changeset.t()}
  def remove_translation(%__MODULE__{data: data} = entity_data, lang_code)
      when is_binary(lang_code) do
    if Multilang.multilang_data?(data) do
      primary = data["_primary_language"]

      if lang_code == primary do
        {:error, :cannot_remove_primary}
      else
        updated_data = Map.delete(data, lang_code)
        __MODULE__.update(entity_data, %{data: updated_data})
      end
    else
      {:error, :not_multilang}
    end
  end

  @doc """
  Gets the title translation for a specific language.

  Reads from `data[lang]["_title"]` (unified JSONB storage). Falls back to
  the old `metadata["translations"]` location for unmigrated records, and
  finally to the `title` column.

  ## Examples

      iex> get_title_translation(record, "en-US")
      "My Product"

      iex> get_title_translation(record, "es-ES")
      "Mi Producto"
  """
  @spec get_title_translation(t(), String.t()) :: String.t() | nil
  def get_title_translation(%__MODULE__{} = entity_data, lang_code)
      when is_binary(lang_code) do
    case Multilang.get_language_data(entity_data.data, lang_code) do
      %{"_title" => title} when is_binary(title) and title != "" ->
        title

      _ ->
        # Transitional fallback: check old metadata location for unmigrated records
        case get_in(entity_data.metadata || %{}, ["translations", lang_code, "title"]) do
          title when is_binary(title) and title != "" -> title
          _ -> entity_data.title
        end
    end
  end

  @doc """
  Sets the title translation for a specific language.

  Stores `_title` in the JSONB `data` column using `put_language_data`.
  For the primary language, also updates the `title` DB column.

  ## Examples

      iex> set_title_translation(record, "es-ES", "Mi Producto")
      {:ok, %EntityData{}}

      iex> set_title_translation(record, "en-US", "My Product")
      {:ok, %EntityData{}}
  """
  @spec set_title_translation(t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def set_title_translation(%__MODULE__{} = entity_data, lang_code, title)
      when is_binary(lang_code) and is_binary(title) do
    # Merge _title into existing raw overrides to preserve other fields
    existing_lang_data = Multilang.get_raw_language_data(entity_data.data, lang_code)
    merged = Map.put(existing_lang_data, "_title", title)
    updated_data = Multilang.put_language_data(entity_data.data, lang_code, merged)

    # If setting primary language, also update the DB column
    primary = (entity_data.data || %{})["_primary_language"] || Multilang.primary_language()
    attrs = %{data: updated_data}
    attrs = if lang_code == primary, do: Map.put(attrs, :title, title), else: attrs

    __MODULE__.update(entity_data, attrs)
  end

  @doc """
  Gets all title translations for a record.

  Returns a map of language codes to title strings.

  ## Examples

      iex> get_all_title_translations(record)
      %{"en-US" => "My Product", "es-ES" => "Mi Producto", "fr-FR" => "Mon Produit"}
  """
  @spec get_all_title_translations(t()) :: %{optional(String.t()) => String.t() | nil}
  def get_all_title_translations(%__MODULE__{} = entity_data) do
    Multilang.enabled_languages()
    |> Map.new(fn lang ->
      {lang, get_title_translation(entity_data, lang)}
    end)
  end

  # ============================================================================
  # Language-aware API
  # ============================================================================

  @doc """
  Resolves translated fields on an entity data record for a given language.

  Resolves the `title` from `_title` in the language's data, and replaces
  the `data` field with the merged language data (primary as base + overrides).

  For the primary language or flat (non-multilang) data, the struct is
  returned with the primary language data resolved. When no translation
  exists for a field, the primary language value is used as fallback.

  > #### Read-only {: .warning}
  >
  > The returned struct is **lossy and display-only**. Its `data` is the
  > flattened single-language map — `_primary_language` and every other
  > language are gone. Never build an update changeset from it: writing it
  > back replaces the row's whole multilang `data` with the one resolved
  > language and permanently deletes the rest.
  >
  > Editors must load the record raw (`get!/1`, no `:lang`) and resolve
  > per-language values for display themselves.

  ## Examples

      iex> resolve_language(record, "es-ES")
      %EntityData{title: "Mi Producto", data: %{"name" => "Acme España", ...}}

      iex> resolve_language(record, "en-US")  # primary language
      %EntityData{title: "My Product", data: %{"name" => "Acme", ...}}
  """
  @spec resolve_language(t(), String.t()) :: t()
  def resolve_language(%__MODULE__{} = record, lang_code) when is_binary(lang_code) do
    resolved_title = get_title_translation(record, lang_code)
    resolved_data = Multilang.get_language_data(record.data, lang_code)

    %{record | title: resolved_title, data: resolved_data}
  end

  @doc """
  Resolves translations on a list of entity data records.

  ## Examples

      iex> resolve_languages(records, "es-ES")
      [%EntityData{title: "Mi Producto"}, ...]
  """
  @spec resolve_languages([t()], String.t()) :: [t()]
  def resolve_languages(records, lang_code) when is_list(records) and is_binary(lang_code) do
    Enum.map(records, &resolve_language(&1, lang_code))
  end

  # Returns the Ecto order_by clause based on the entity's sort_mode setting.
  # "manual" mode sorts by position ASC (with nulls last via date_created fallback).
  # "auto" mode (default) sorts by date_created DESC.
  #
  # Accepts opts with :sort_mode to skip the entity lookup when the caller
  # already has the entity loaded. Falls back to a DB lookup by entity_uuid.
  defp resolve_sort_order(entity_uuid, opts) do
    mode =
      case Keyword.get(opts, :sort_mode) do
        nil -> entity_sort_mode_from_db(entity_uuid)
        mode -> mode
      end

    sort_order_for_mode(mode)
  end

  defp entity_sort_mode_from_db(entity_uuid) when is_binary(entity_uuid) do
    case Entities.get_entity(entity_uuid) do
      %{settings: %{"sort_mode" => mode}} -> mode
      _ -> "auto"
    end
  end

  defp entity_sort_mode_from_db(_), do: "auto"

  defp sort_order_for_mode("manual"), do: [asc_nulls_last: :position, desc: :date_created]
  defp sort_order_for_mode(_), do: [desc: :date_created]

  # Applies :lang option to a single record if present in opts
  defp maybe_resolve_lang(record, opts) when is_list(opts) do
    case Keyword.get(opts, :lang) do
      nil -> record
      lang -> resolve_language(record, lang)
    end
  end

  # Applies :lang option to a list of records if present in opts
  defp maybe_resolve_langs(records, opts) when is_list(records) and is_list(opts) do
    case Keyword.get(opts, :lang) do
      nil -> records
      lang -> resolve_languages(records, lang)
    end
  end

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
