defmodule PhoenixKitEntities do
  @moduledoc """
  Dynamic entity system for PhoenixKit.

  This module provides both the Ecto schema definition and business logic for
  managing custom content types (entities) with flexible field schemas.

  ## Schema Fields

  - `name`: Unique identifier for the entity (e.g., "brand", "product")
  - `display_name`: Human-readable singular name shown in UI (e.g., "Brand")
  - `display_name_plural`: Human-readable plural name (e.g., "Brands")
  - `description`: Description of what this entity represents
  - `icon`: Icon identifier for UI display (hero icons)
  - `status`: Workflow status string - one of "draft", "published", or "archived"
  - `fields_definition`: JSONB array of field definitions
  - `settings`: JSONB map of entity-specific settings
  - `created_by`: User ID of the admin who created the entity
  - `date_created`: When the entity was created
  - `date_updated`: When the entity was last modified

  ## Field Definition Structure

  Each field in `fields_definition` is a map with:
  - `type`: Field type (text, textarea, number, boolean, date, select, etc.)
  - `key`: Unique field identifier (snake_case)
  - `label`: Display label for the field
  - `required`: Whether the field is required
  - `default`: Default value
  - `validation`: Map of validation rules
  - `options`: Array of options (for select, radio, checkbox types)

  ## Core Functions

  ### Entity Management
  - `list_entities/0` - Get all entities
  - `list_active_entities/0` - Get only active entities
  - `get_entity!/1` - Get an entity by ID (raises if not found)
  - `get_entity_by_name/1` - Get an entity by its name
  - `create_entity/1` - Create a new entity
  - `update_entity/2` - Update an existing entity
  - `delete_entity/1` - Delete an entity (and all its data)
  - `change_entity/2` - Get changeset for forms

  ### System Settings
  - `enabled?/0` - Check if entities system is enabled
  - `enable_system/0` - Enable the entities system
  - `disable_system/0` - Disable the entities system
  - `get_config/0` - Get current system configuration
  - `get_max_per_user/0` - Get max entities per user limit
  - `validate_user_entity_limit/1` - Check if user can create more entities

  ## Usage Examples

      # Check if system is enabled
      if PhoenixKitEntities.enabled?() do
        # System is active
      end

      # Create a brand entity
      # Note: fields_definition requires string keys, not atom keys
      {:ok, entity} = PhoenixKitEntities.create_entity(%{
        name: "brand",
        display_name: "Brand",
        display_name_plural: "Brands",
        description: "Brand content type for company profiles",
        icon: "hero-building-office",
        created_by_uuid: admin_user.uuid,
        fields_definition: [
          %{"type" => "text", "key" => "name", "label" => "Name", "required" => true},
          %{"type" => "textarea", "key" => "tagline", "label" => "Tagline"},
          %{"type" => "rich_text", "key" => "description", "label" => "Description", "required" => true},
          %{"type" => "select", "key" => "industry", "label" => "Industry",
            "options" => ["Technology", "Manufacturing", "Retail"]},
          %{"type" => "date", "key" => "founded_date", "label" => "Founded Date"},
          %{"type" => "boolean", "key" => "featured", "label" => "Featured Brand"}
        ]
      })

      # Get entity by name
      entity = PhoenixKitEntities.get_entity_by_name("brand")

      # List all active entities
      entities = PhoenixKitEntities.list_active_entities()
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  use PhoenixKit.Module
  use Gettext, backend: PhoenixKitEntities.Gettext

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Events
  alias PhoenixKitEntities.FieldTypes
  alias PhoenixKitEntities.Managed
  alias PhoenixKitEntities.Mirror.Exporter
  alias PhoenixKitEntities.Mirror.Storage
  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @valid_statuses ~w(draft published archived)

  @derive {Jason.Encoder,
           only: [
             :uuid,
             :name,
             :display_name,
             :display_name_plural,
             :description,
             :icon,
             :status,
             :fields_definition,
             :settings,
             :position,
             :date_created,
             :date_updated
           ]}

  schema "phoenix_kit_entities" do
    field(:name, :string)
    field(:display_name, :string)
    field(:display_name_plural, :string)
    field(:description, :string)
    field(:icon, :string)
    field(:status, :string, default: "published")
    field(:fields_definition, {:array, :map})
    field(:settings, :map)
    field(:position, :integer, default: 0)
    field(:created_by_uuid, UUIDv7)
    field(:date_created, :utc_datetime)
    field(:date_updated, :utc_datetime)

    belongs_to(:creator, User,
      foreign_key: :created_by_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7
    )

    has_many(:entity_data, PhoenixKitEntities.EntityData,
      foreign_key: :entity_uuid,
      references: :uuid
    )
  end

  @doc """
  Creates a changeset for entity creation and updates.

  Validates that name is unique, fields_definition is valid, and all required fields are present.
  Automatically sets date_created on new records.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(entity, attrs) do
    entity
    |> cast(attrs, [
      :name,
      :display_name,
      :display_name_plural,
      :description,
      :icon,
      :status,
      :fields_definition,
      :settings,
      :position,
      :created_by_uuid,
      :date_created,
      :date_updated
    ])
    |> validate_required([:name, :display_name, :display_name_plural])
    |> validate_creator_reference()
    |> validate_length(:name, min: 2, max: 50)
    |> validate_length(:display_name, min: 2, max: 100)
    |> validate_length(:display_name_plural, min: 2, max: 100)
    |> validate_length(:description, max: 500)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_format(:name, ~r/^[a-z][a-z0-9_]*$/,
      message:
        "must start with a letter and contain only lowercase letters, numbers, and underscores"
    )
    |> validate_name_uniqueness()
    |> validate_fields_definition()
    # Core's chain names this index `phoenix_kit_entities_name_uidx`, not the
    # `phoenix_kit_entities_name_index` Ecto derives — without the explicit
    # name the declaration can never fire. `validate_name_uniqueness/1` above
    # catches the common case at changeset time; this constraint is the
    # race-window backstop for two concurrent creates, which is exactly when a
    # raw Ecto.ConstraintError raise is least acceptable.
    |> unique_constraint(:name, name: :phoenix_kit_entities_name_uidx)
    |> maybe_set_timestamps()
  end

  defp validate_creator_reference(changeset) do
    created_by_uuid = get_field(changeset, :created_by_uuid)

    if is_nil(created_by_uuid) do
      add_error(
        changeset,
        :created_by_uuid,
        "created_by_uuid must be present"
      )
    else
      changeset
    end
  end

  defp validate_name_uniqueness(changeset) do
    name = get_field(changeset, :name)
    current_uuid = get_field(changeset, :uuid)

    if is_nil(name) or name == "" do
      changeset
    else
      case get_entity_by_name(name) do
        nil -> changeset
        existing when current_uuid != nil and existing.uuid == current_uuid -> changeset
        _existing -> add_error(changeset, :name, "has already been taken")
      end
    end
  end

  defp validate_fields_definition(changeset) do
    case get_field(changeset, :fields_definition) do
      nil ->
        put_change(changeset, :fields_definition, [])

      fields when is_list(fields) ->
        validate_each_field_definition(changeset, fields)

      _invalid ->
        add_error(changeset, :fields_definition, "must be a list of field definitions")
    end
  end

  defp validate_each_field_definition(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      validate_single_field_definition(acc, field)
    end)
  end

  defp validate_single_field_definition(changeset, field) when is_map(field) do
    required_keys = ["type", "key", "label"]
    missing_keys = required_keys -- Map.keys(field)

    if Enum.empty?(missing_keys) do
      validate_field_type(changeset, field)
    else
      add_error(
        changeset,
        :fields_definition,
        "field missing required keys: #{Enum.join(missing_keys, ", ")}"
      )
    end
  end

  defp validate_single_field_definition(changeset, _invalid) do
    add_error(changeset, :fields_definition, "each field must be a map")
  end

  # `FieldTypes.list_types/0` is the source of truth for every type with a
  # real `FieldType` entry; `image`/`relation` are placeholder types that
  # render a "coming soon" box in `FormBuilder.build_field/3` but have no
  # `FieldType` map of their own yet, so they're appended explicitly rather
  # than duplicating the whole list by hand (which had drifted before —
  # this allowlist and `FieldTypes.list_types/0` are meant to be the same
  # set of types).
  defp validate_field_type(changeset, field) do
    # image/video graduated into the FieldTypes registry (2026-08-18);
    # relation remains the lone placeholder appended by hand.
    valid_types = FieldTypes.list_types() ++ ~w(relation)

    if field["type"] in valid_types do
      changeset
    else
      add_error(
        changeset,
        :fields_definition,
        "invalid field type '#{field["type"]}' for field '#{field["key"]}'"
      )
    end
  end

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

  defp notify_entity_event({:ok, %__MODULE__{} = entity}, :created, opts) do
    Events.broadcast_entity_created(entity.uuid)
    maybe_mirror_entity(entity)
    log_entity_activity(entity, "entity.created", opts)
    {:ok, entity}
  end

  defp notify_entity_event({:ok, %__MODULE__{} = entity}, :updated, opts) do
    Events.broadcast_entity_updated(entity.uuid)
    maybe_mirror_entity(entity)
    log_entity_activity(entity, "entity.updated", opts)
    {:ok, entity}
  end

  defp notify_entity_event({:ok, %__MODULE__{} = entity}, :deleted, opts) do
    Events.broadcast_entity_deleted(entity.uuid)
    maybe_delete_mirrored_entity(entity)
    log_entity_activity(entity, "entity.deleted", opts)
    {:ok, entity}
  end

  defp notify_entity_event({:error, _} = result, event, opts) do
    log_entity_error_activity(event, opts)
    result
  end

  defp notify_entity_event(result, _event, _opts), do: result

  # Records an entity-lifecycle activity entry. The actor UUID comes
  # from the caller's `:actor_uuid` opt (the user performing the
  # mutation) rather than `entity.created_by_uuid` (the original
  # creator) — they are not the same person on update/delete.
  # Non-crashing — see `PhoenixKitEntities.ActivityLog` for the guard
  # semantics.
  defp log_entity_activity(%__MODULE__{} = entity, action, opts) do
    PhoenixKitEntities.ActivityLog.log(%{
      action: action,
      mode: "manual",
      actor_uuid: Keyword.get(opts, :actor_uuid) || entity.created_by_uuid,
      resource_type: "entity",
      resource_uuid: entity.uuid,
      metadata: %{
        "name" => entity.name,
        "display_name" => entity.display_name,
        "status" => entity.status
      }
    })
  end

  # Records the user-initiated action even when the changeset failed,
  # so the audit trail covers attempts (not just successes). Marked
  # with `db_pending: true` so consumers can distinguish from
  # successful rows.
  defp log_entity_error_activity(event, opts) do
    PhoenixKitEntities.ActivityLog.log(%{
      action: "entity.#{event}",
      mode: "manual",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "entity",
      metadata: %{"db_pending" => true}
    })
  end

  # Mirror export helpers for auto-sync (per-entity settings).
  # Filesystem export is fire-and-forget after the DB commit returns;
  # supervised under PhoenixKit.TaskSupervisor so a crashing exporter
  # doesn't take down the caller and the task is restartable.
  defp maybe_mirror_entity(entity) do
    if mirror_definitions_enabled?(entity) do
      Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, fn ->
        Exporter.export_entity(entity)
      end)
    end
  end

  defp maybe_delete_mirrored_entity(entity) do
    # Delete the file if it exists (regardless of current setting)
    # This ensures cleanup when entity is deleted
    if Storage.entity_exists?(entity.name) do
      Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, fn ->
        Storage.delete_entity(entity.name)
      end)
    end
  end

  @doc """
  Returns the list of entities ordered by creation date.

  ## Examples

      iex> PhoenixKitEntities.list_entities()
      [%PhoenixKit.Entities{}, ...]
  """
  @spec list_entities(keyword()) :: [t()]
  def list_entities(opts \\ []) do
    __MODULE__
    |> order_by([e], asc: e.position, desc: e.date_created)
    |> preload([:creator])
    |> repo().all()
    |> maybe_reject_managed(opts)
    |> maybe_resolve_langs(opts)
  end

  # `include_managed: false` hides blueprints owned by other modules
  # (catalogue attribute sets etc.) — they have their own admin UI.
  defp maybe_reject_managed(entities, opts) do
    if Keyword.get(opts, :include_managed, true) do
      entities
    else
      Enum.reject(entities, &Managed.managed?/1)
    end
  end

  @doc """
  Returns the list of active (published) entities.

  ## Examples

      iex> PhoenixKitEntities.list_active_entities()
      [%PhoenixKit.Entities{status: "published"}, ...]
  """
  @spec list_active_entities(keyword()) :: [t()]
  def list_active_entities(opts \\ []) do
    from(e in __MODULE__,
      where: e.status == "published",
      order_by: [asc: e.position, desc: e.date_created],
      preload: [:creator]
    )
    |> repo().all()
    |> maybe_resolve_langs(opts)
  end

  @doc """
  Returns a lightweight list of published entity summaries for sidebar display.

  Selects only sidebar-relevant fields without preloading associations.
  Supports `:lang` option for translation resolution.
  """
  @spec list_entity_summaries(keyword()) :: [map()]
  def list_entity_summaries(opts \\ []) do
    summaries =
      from(e in __MODULE__,
        where: e.status == "published",
        order_by: [asc: e.position, desc: e.date_created],
        select: %{
          name: e.name,
          display_name: e.display_name,
          display_name_plural: e.display_name_plural,
          description: e.description,
          icon: e.icon,
          settings: e.settings
        }
      )
      |> repo().all()

    case Keyword.get(opts, :lang) do
      nil -> summaries
      lang -> Enum.map(summaries, &resolve_summary_language(&1, lang))
    end
  end

  # Resolves display_name / display_name_plural / description on a summary map,
  # matching the behaviour of resolve_language/2 without a struct round-trip.
  defp resolve_summary_language(summary, lang_code) do
    translations_map = get_in(summary, [:settings, "translations"]) || %{}
    translations = lookup_translation(translations_map, lang_code)

    summary
    |> maybe_put_translation(:display_name, translations["display_name"])
    |> maybe_put_translation(:display_name_plural, translations["display_name_plural"])
    |> maybe_put_translation(:description, translations["description"])
  end

  defp maybe_put_translation(summary, _field, nil), do: summary
  defp maybe_put_translation(summary, _field, ""), do: summary
  defp maybe_put_translation(summary, field, value), do: Map.put(summary, field, value)

  # Looks up translation overrides by locale, tolerating base/dialect mismatches.
  #
  # Translations are stored under whatever key `set_entity_translation` saw —
  # typically the dialect form (e.g. `"es-ES"`). Callers may query with either
  # the dialect (`Gettext.get_locale/1` returns `"en-US"` etc.) or a base code
  # (URL params expose `"en"`). Without normalization the dialect/base mismatch
  # silently misses and the UI falls back to primary-language labels.
  #
  # Match priority:
  # 1. Exact key match (`"es-ES"` → `"es-ES"`).
  # 2. Same base code (`"es"` → first `"es-*"` translation, deterministic via
  #    sort).
  defp lookup_translation(translations_map, lang_code)
       when is_map(translations_map) and is_binary(lang_code) do
    case Map.get(translations_map, lang_code) do
      %{} = exact ->
        exact

      _ ->
        base = safe_extract_base(lang_code)

        translations_map
        |> Enum.filter(fn {key, _v} ->
          is_binary(key) and safe_extract_base(key) == base and base != nil
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> case do
          [{_key, value} | _] when is_map(value) -> value
          _ -> %{}
        end
    end
  end

  defp lookup_translation(_translations_map, _lang_code), do: %{}

  defp safe_extract_base(code) when is_binary(code) and code != "" do
    DialectMapper.extract_base(code)
  rescue
    _ -> nil
  end

  defp safe_extract_base(_), do: nil

  @doc """
  Gets a single entity by integer ID or UUID.

  Returns the entity if found, nil otherwise.

  Accepts:
  - Integer ID (e.g., 123)
  - UUID string (e.g., "550e8400-e29b-41d4-a716-446655440000")
  - Integer string (e.g., "123")

  ## Examples

      iex> PhoenixKitEntities.get_entity(123)
      %PhoenixKit.Entities{}

      iex> PhoenixKitEntities.get_entity("550e8400-e29b-41d4-a716-446655440000")
      %PhoenixKit.Entities{}

      iex> PhoenixKitEntities.get_entity(456)
      nil
  """
  @spec get_entity(term(), keyword()) :: t() | nil
  def get_entity(uuid, opts \\ [])

  def get_entity(uuid, opts) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid) do
      case repo().get_by(__MODULE__, uuid: uuid) do
        nil -> nil
        entity -> entity |> repo().preload(:creator) |> maybe_resolve_lang(opts)
      end
    else
      nil
    end
  end

  def get_entity(_, _opts), do: nil

  @doc """
  Gets a single entity by integer ID or UUID.

  Raises `Ecto.NoResultsError` if the entity does not exist.

  ## Examples

      iex> PhoenixKitEntities.get_entity!(123)
      %PhoenixKit.Entities{}

      iex> PhoenixKitEntities.get_entity!(456)
      ** (Ecto.NoResultsError)
  """
  @spec get_entity!(term(), keyword()) :: t()
  def get_entity!(id, opts \\ []) do
    case get_entity(id, opts) do
      nil -> raise Ecto.NoResultsError, queryable: __MODULE__
      entity -> entity
    end
  end

  @doc """
  Gets a single entity by its unique name.

  Returns the entity if found, nil otherwise.

  ## Examples

      iex> PhoenixKitEntities.get_entity_by_name("brand")
      %PhoenixKit.Entities{}

      iex> PhoenixKitEntities.get_entity_by_name("invalid")
      nil
  """
  @spec get_entity_by_name(String.t(), keyword()) :: t() | nil
  def get_entity_by_name(name, opts \\ []) when is_binary(name) do
    case repo().get_by(__MODULE__, name: name) do
      nil -> nil
      entity -> maybe_resolve_lang(entity, opts)
    end
  end

  @doc """
  Creates an entity.

  ## Examples

      iex> PhoenixKitEntities.create_entity(%{name: "brand", display_name: "Brand"})
      {:ok, %PhoenixKit.Entities{}}

      iex> PhoenixKitEntities.create_entity(%{name: ""})
      {:error, %Ecto.Changeset{}}

  Note: `created_by` is auto-filled with the first admin or user ID if not provided,
  but only if at least one user exists in the system. If no users exist, the changeset
  will fail with a validation error on `created_by`.
  """
  @spec create_entity(map(), keyword()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t() | :managed_blueprint}
  def create_entity(attrs \\ %{}, opts \\ []) do
    with :ok <- Managed.validate_creation(attrs, opts) do
      attrs =
        attrs
        |> maybe_add_created_by()
        |> maybe_add_entity_position()

      %__MODULE__{}
      |> changeset(attrs)
      |> repo().insert()
      |> notify_entity_event(:created, opts)
    end
  end

  # Auto-assign a position when the caller hasn't specified one — places
  # the new entity at the end of the manual-order list. Existing tests /
  # callers that pass `:position` keep control.
  # Race-tolerant: two concurrent inserts can read the same MAX and both
  # write n+1; ties resolve via the date_created secondary sort and
  # clear on the next drag.
  defp maybe_add_entity_position(attrs) when is_map(attrs) do
    # Value, not key presence — see `maybe_add_created_by/1` above. An explicit
    # `position: nil` meant "already decided" here, so the auto-position was
    # skipped and the cast nil also bypassed the schema's `default: 0`, leaving
    # the entity unordered.
    has_position = not is_nil(Map.get(attrs, :position) || Map.get(attrs, "position"))

    if has_position do
      attrs
    else
      Map.put(attrs, :position, next_entity_position())
    end
  end

  # Auto-fill created_by_uuid with first admin if not provided
  # Unlike `EntityData`, an entity always has an author: `phoenix_kit_entities`
  # has no anonymous creation path and its `created_by_uuid` stays NOT NULL, so
  # an explicit `created_by_uuid: nil` is honoured as "no creator" and reported
  # by `validate_creator_reference/1` as a changeset error rather than being
  # quietly replaced with an administrator.
  defp maybe_add_created_by(attrs) when is_map(attrs) do
    has_created_by_uuid =
      Map.has_key?(attrs, :created_by_uuid) or Map.has_key?(attrs, "created_by_uuid")

    if has_created_by_uuid do
      attrs
    else
      creator_uuid = Auth.get_first_admin_uuid() || Auth.get_first_user_uuid()

      # Match the caller's key form — mixing atom and string keys makes Ecto's
      # cast/3 raise. Same precedence as `EntityData`'s `attr_key/3`: an existing
      # key wins in either form, otherwise follow the shape of the map.
      key =
        cond do
          Map.has_key?(attrs, :created_by_uuid) -> :created_by_uuid
          Map.has_key?(attrs, "created_by_uuid") -> "created_by_uuid"
          Enum.any?(Map.keys(attrs), &is_binary/1) -> "created_by_uuid"
          true -> :created_by_uuid
        end

      if creator_uuid, do: Map.put(attrs, key, creator_uuid), else: attrs
    end
  end

  @doc """
  Updates an entity.

  ## Examples

      iex> PhoenixKitEntities.update_entity(entity, %{display_name: "Updated"})
      {:ok, %PhoenixKit.Entities{}}

      iex> PhoenixKitEntities.update_entity(entity, %{name: ""})
      {:error, %Ecto.Changeset{}}
  """
  @spec update_entity(t(), map(), keyword()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t() | :managed_blueprint | :locked_key}
  def update_entity(%__MODULE__{} = entity, attrs, opts \\ []) do
    # Managed blueprints (another module's contract riding entities —
    # e.g. catalogue attribute sets): the write path itself refuses
    # identity renames and locked-key changes from anyone but the owner.
    case Managed.validate_mutation(entity, attrs, opts) do
      :ok ->
        entity
        |> changeset(attrs)
        |> repo().update()
        |> notify_entity_event(:updated, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes an entity.

  Note: This will also delete all associated entity_data records due to the
  ON DELETE CASCADE constraint defined in the database migration (V17).

  ## Examples

      iex> PhoenixKitEntities.delete_entity(entity)
      {:ok, %PhoenixKit.Entities{}}

      iex> PhoenixKitEntities.delete_entity(entity)
      {:error, %Ecto.Changeset{}}
  """
  @spec delete_entity(t(), keyword()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t() | term()}
  def delete_entity(%__MODULE__{} = entity, opts \\ []) do
    case Managed.validate_delete(entity, opts) do
      :ok ->
        repo().delete(entity)
        |> notify_entity_event(:deleted, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking entity changes.

  ## Examples

      iex> PhoenixKitEntities.change_entity(entity)
      %Ecto.Changeset{data: %PhoenixKit.Entities{}}
  """
  @spec change_entity(t(), map()) :: Ecto.Changeset.t()
  def change_entity(%__MODULE__{} = entity, attrs \\ %{}) do
    changeset(entity, attrs)
  end

  @doc """
  Returns the next available `position` for a new entity — i.e. one
  past the highest currently used. Falls back to `1` when the table is
  empty.
  """
  @spec next_entity_position() :: integer()
  def next_entity_position do
    max =
      __MODULE__
      |> select([e], max(e.position))
      |> repo().one()

    case max do
      nil -> 1
      n when is_integer(n) -> n + 1
    end
  end

  @doc """
  Re-indexes the supplied list of entity UUIDs into positions `1..N`
  in the order given.

  This is the entry point for the drag-and-drop reorder event from the
  Entities admin LV. UUIDs not in the list are left at their current
  positions; missing UUIDs in the table are silently skipped (the LV
  always sends the full visible list, so partial sends are a stale-DOM
  artifact and not worth blowing up over).

  Wraps both passes in a single transaction. Returns `:ok` on success
  or `{:error, reason}` on transaction failure.
  """
  # Same cap as `EntityData.bulk_update_positions/2`. Reorder is a
  # per-page action; even a workspace with hundreds of entities would
  # never paint a thousand at once.
  @reorder_entities_max_uuids 1000

  @spec reorder_entities([Ecto.UUID.t()], keyword()) :: :ok | {:error, term()}
  def reorder_entities(ordered_uuids, opts \\ [])

  def reorder_entities(ordered_uuids, opts)
      when is_list(ordered_uuids) and length(ordered_uuids) > @reorder_entities_max_uuids do
    log_entity_reorder_rejected(:too_many_uuids, length(ordered_uuids), opts)
    {:error, :too_many_uuids}
  end

  def reorder_entities(ordered_uuids, opts) when is_list(ordered_uuids) do
    # Dedup defensively (last occurrence wins, same shape as
    # `EntityData.bulk_update_positions/2`).
    unique_uuids =
      ordered_uuids
      |> Enum.reverse()
      |> Enum.uniq()
      |> Enum.reverse()

    case write_entity_positions(unique_uuids) do
      {:ok, _} ->
        # Audit-log the reorder. Metadata stays PII-safe — count + the
        # first uuid are enough to attribute the action and locate it
        # in the table; the full ordered list would bloat the row and
        # add no diagnostic value beyond what `Entities.list_entities/0`
        # at the same instant already shows.
        log_entity_reorder_activity(unique_uuids, opts)

        # Reuse the existing `:entity_updated` event — it's already
        # wired to invalidate the Dashboard sidebar cache and refresh
        # any open Entities/EntitiesSettings/DataNavigator LVs that
        # render entity-keyed lists. Broadcasting once with the first
        # uuid is sufficient since every listener re-fetches the full
        # list on receipt.
        broadcast_first_entity_updated(unique_uuids)

        :ok

      {:error, reason} ->
        # Cover the user-initiated action even when the DB write fails.
        # `db_pending: true` lets log consumers distinguish from
        # successful rows; the actor still gets attribution in the
        # audit trail.
        log_entity_reorder_activity_error(unique_uuids, reason, opts)
        {:error, reason}
    end
  end

  defp write_entity_positions(unique_uuids) do
    pairs = Enum.with_index(unique_uuids, 1)
    now = UtilsDate.utc_now()

    repo().transaction(fn ->
      Enum.each(pairs, fn {uuid, idx} ->
        from(e in __MODULE__, where: e.uuid == ^uuid)
        |> repo().update_all(set: [position: idx, date_updated: now])
      end)
    end)
  end

  defp broadcast_first_entity_updated([uuid | _]) when is_binary(uuid),
    do: Events.broadcast_entity_updated(uuid)

  defp broadcast_first_entity_updated(_), do: :ok

  defp log_entity_reorder_activity([], _opts), do: :ok

  defp log_entity_reorder_activity([first_uuid | _rest] = uuids, opts) do
    PhoenixKitEntities.ActivityLog.log(%{
      action: "entity.reordered",
      mode: "manual",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "entity",
      resource_uuid: first_uuid,
      metadata: %{"count" => length(uuids)}
    })
  end

  defp log_entity_reorder_activity_error([], _reason, _opts), do: :ok

  defp log_entity_reorder_activity_error([first_uuid | _rest] = uuids, _reason, opts) do
    PhoenixKitEntities.ActivityLog.log(%{
      action: "entity.reordered",
      mode: "manual",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "entity",
      resource_uuid: first_uuid,
      metadata: %{"count" => length(uuids), "db_pending" => true}
    })
  end

  defp log_entity_reorder_rejected(reason, count, opts) do
    PhoenixKitEntities.ActivityLog.log(%{
      action: "entity.reordered",
      mode: "manual",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "entity",
      metadata: %{
        "count" => count,
        "db_pending" => true,
        "rejected" => to_string(reason)
      }
    })
  end

  @doc """
  Gets summary statistics for the entities system.

  Returns counts and metrics useful for admin dashboards.

  ## Examples

      iex> PhoenixKitEntities.get_system_stats()
      %{total_entities: 5, active_entities: 4, total_data_records: 150}
  """
  @spec get_system_stats() :: map()
  def get_system_stats do
    entities_query = from(e in __MODULE__)
    data_query = from(d in PhoenixKitEntities.EntityData)

    total_entities = repo().aggregate(entities_query, :count)

    active_entities =
      repo().aggregate(from(e in entities_query, where: e.status == "published"), :count)

    total_data_records = repo().aggregate(data_query, :count)

    %{
      total_entities: total_entities,
      active_entities: active_entities,
      total_data_records: total_data_records
    }
  end

  @doc """
  Counts the total number of entities created by a user.

  ## Examples

      iex> PhoenixKitEntities.count_user_entities(1)
      5
  """
  @spec count_user_entities(String.t()) :: non_neg_integer()
  def count_user_entities(user_uuid) when is_binary(user_uuid) do
    # Managed blueprints (owned by other modules, provisioned
    # programmatically) don't count against the per-user cap — an admin
    # creating catalogue attribute sets isn't "creating entities".
    from(e in __MODULE__,
      where: e.created_by_uuid == ^user_uuid,
      where: fragment("COALESCE(? ->> 'managed_by', '') = ''", e.settings),
      select: count(e.uuid)
    )
    |> repo().one()
  end

  @doc """
  Counts the total number of entities in the system.

  ## Examples

      iex> PhoenixKitEntities.count_entities()
      15
  """
  @spec count_entities() :: non_neg_integer()
  def count_entities do
    from(e in __MODULE__, select: count(e.uuid))
    |> repo().one()
  end

  @doc """
  Counts the total number of entity data records across all entities.

  ## Examples

      iex> PhoenixKitEntities.count_all_entity_data()
      243
  """
  @spec count_all_entity_data() :: non_neg_integer()
  def count_all_entity_data do
    from(d in PhoenixKitEntities.EntityData, select: count(d.uuid))
    |> repo().one()
  end

  @doc """
  Validates that a user hasn't exceeded their entity creation limit.

  Checks the current number of entities created by the user against the system limit.
  Returns `{:ok, :valid}` if within limits, `{:error, reason}` if limit exceeded.

  ## Examples

      iex> PhoenixKitEntities.validate_user_entity_limit(1)
      {:ok, :valid}

      iex> PhoenixKitEntities.validate_user_entity_limit(1)
      {:error, {:user_entity_limit_reached, 100}}

  Error tuples flow through `PhoenixKitEntities.Errors.message/1` for
  user-facing strings.
  """
  @spec validate_user_entity_limit(String.t()) ::
          {:ok, :valid} | {:error, {:user_entity_limit_reached, non_neg_integer()}}
  def validate_user_entity_limit(user_uuid) when is_binary(user_uuid) do
    max_entities = get_max_per_user()
    current_count = count_user_entities(user_uuid)

    if current_count < max_entities do
      {:ok, :valid}
    else
      {:error, {:user_entity_limit_reached, max_entities}}
    end
  end

  @impl PhoenixKit.Module
  @doc """
  Checks if the entities system is enabled.

  Returns true if the "entities_enabled" setting is true.

  ## Examples

      iex> PhoenixKitEntities.enabled?()
      false
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Settings.get_boolean_setting("entities_enabled", false)
  rescue
    _ -> false
  catch
    # Settings supervisor may exit during sandbox shutdown; treat as disabled.
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  @doc """
  Enables the entities system.

  Sets the "entities_enabled" setting to true and logs a
  `module.entities.enabled` activity row.

  ## Options

    * `:actor_uuid` — UUID of the user toggling the system. Threaded
      through to the activity log entry. `nil` is allowed when the
      caller doesn't have a scope (system jobs).

  ## Examples

      iex> PhoenixKitEntities.enable_system(actor_uuid: admin.uuid)
      {:ok, %Setting{}}
  """
  @spec enable_system(keyword()) :: {:ok, term()} | {:error, term()}
  def enable_system(opts \\ []) do
    result = Settings.update_boolean_setting_with_module("entities_enabled", true, module_key())
    log_module_toggle("module.entities.enabled", result, opts)
    result
  end

  @impl PhoenixKit.Module
  @doc """
  Disables the entities system.

  Sets the "entities_enabled" setting to false and logs a
  `module.entities.disabled` activity row.

  ## Options

    * `:actor_uuid` — see `enable_system/1`.

  ## Examples

      iex> PhoenixKitEntities.disable_system(actor_uuid: admin.uuid)
      {:ok, %Setting{}}
  """
  @spec disable_system(keyword()) :: {:ok, term()} | {:error, term()}
  def disable_system(opts \\ []) do
    result = Settings.update_boolean_setting_with_module("entities_enabled", false, module_key())
    log_module_toggle("module.entities.disabled", result, opts)
    result
  end

  defp log_module_toggle(action, result, opts) do
    metadata =
      case result do
        {:ok, _} -> %{"setting" => "entities_enabled"}
        {:error, _} -> %{"setting" => "entities_enabled", "db_pending" => true}
      end

    PhoenixKitEntities.ActivityLog.log(%{
      action: action,
      mode: "manual",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "module",
      metadata: metadata
    })
  end

  @doc """
  Gets the maximum number of entities a single user can create.

  Returns the system-wide limit for entity creation per user.
  Defaults to 100 if not set.

  ## Examples

      iex> PhoenixKitEntities.get_max_per_user()
      100
  """
  @spec get_max_per_user() :: non_neg_integer()
  def get_max_per_user do
    Settings.get_integer_setting("entities_max_per_user", 100)
  end

  @impl PhoenixKit.Module
  @doc """
  Gets the current entities system configuration.

  Returns a map with the current settings.

  ## Examples

      iex> PhoenixKitEntities.get_config()
      %{enabled: false, max_per_user: 100, allow_relations: true, file_upload: false, entity_count: 0, total_data_count: 0}

  Count queries are wrapped in `safe_count/1` so `get_config/0` works
  outside of a sandbox checkout (e.g. unit-test contexts that don't
  use `DataCase`) — same defensive pattern as `enabled?/0`.
  """
  @spec get_config() :: map()
  def get_config do
    %{
      enabled: enabled?(),
      max_per_user: get_max_per_user(),
      allow_relations: Settings.get_boolean_setting("entities_allow_relations", true),
      file_upload: Settings.get_boolean_setting("entities_file_upload", false),
      entity_count: safe_count(&count_entities/0),
      total_data_count: safe_count(&count_all_entity_data/0)
    }
  end

  defp safe_count(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  # ============================================================================
  # Module Behaviour Callbacks
  # ============================================================================

  @impl PhoenixKit.Module
  @spec module_key() :: String.t()
  def module_key, do: "entities"

  @impl PhoenixKit.Module
  @spec migration_module() :: module()
  def migration_module, do: PhoenixKitEntities.Migrations

  @impl PhoenixKit.Module
  @spec module_name() :: String.t()
  def module_name, do: "Entities"

  @impl PhoenixKit.Module
  @spec permission_metadata() :: map()
  def permission_metadata do
    %{
      key: "entities",
      # gettext_noop/1 anchors extraction to this definition site so
      # `mix gettext.extract` keeps finding the msgid even if the literal
      # `gettext("Entities")` calls elsewhere in this package (tab page
      # titles) get reworded independently.
      label: gettext_noop("Entities"),
      icon: "hero-cube-transparent",
      description: "Dynamic content types and custom data structures",
      # Renders the label translated in the admin permissions matrix, the
      # same way the sidebar tabs below translate theirs.
      gettext_backend: PhoenixKitEntities.Gettext,
      gettext_domain: "default"
    }
  end

  # Project-extension catalog entry for the `phoenix_kit_projects` hub —
  # duck-typed contract (its Extensions.Registry discovers this function on
  # every loaded module; no dependency on that package, no `@impl`). The
  # Data tab config-links ONE entity per project and lists its records
  # read-only; mutations stay in the entities admin.
  def phoenix_kit_project_extensions do
    [
      %{
        key: "entities_data",
        name: "Data",
        description: "Link an entity and browse its records inside the project",
        icon: "hero-cube-transparent",
        module_key: "entities",
        default_enabled: false,
        tabs: [
          %{
            key: "data",
            label: "Data",
            icon: "hero-cube-transparent",
            lv: PhoenixKitEntities.Web.ProjectDataLive
          }
        ],
        config_schema: [
          %{key: "entity_uuid", type: :string, label: "Entity UUID"}
        ],
        permission_actions: [:view]
      }
    ]
  end

  @impl PhoenixKit.Module
  def js_sources do
    [
      %{
        app: :phoenix_kit_entities,
        file: "static/assets/phoenix_kit_entities.js",
        global: "PhoenixKitEntitiesHooks"
      }
    ]
  end

  @impl PhoenixKit.Module
  @spec admin_tabs() :: [PhoenixKit.Dashboard.Tab.t()]
  def admin_tabs do
    [
      Tab.new!(
        id: :admin_entities,
        label: gettext_noop("Entities"),
        icon: "hero-cube",
        path: "entities",
        priority: 540,
        level: :admin,
        permission: "entities",
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        dynamic_children: &__MODULE__.entities_children/1,
        gettext_backend: PhoenixKitEntities.Gettext,
        gettext_domain: "default"
      )
    ]
  end

  # ETS cache TTL for entity summaries (30 seconds)
  @entities_cache_ttl_ms 30_000
  @entities_cache_key :entities_children_cache

  @doc """
  Invalidates the cached entity summaries in the Dashboard Registry's ETS table.
  Called when entity lifecycle PubSub events are received.
  """
  @spec invalidate_entities_cache() :: :ok
  def invalidate_entities_cache do
    alias PhoenixKit.Dashboard.Registry, as: DashboardRegistry

    if DashboardRegistry.initialized?() do
      # Delete all entries for this cache key across all locales
      # Pattern matches: {{:entities_children_cache, _}, _, _}
      :ets.match_delete(DashboardRegistry.ets_table(), {{@entities_cache_key, :_}, :_, :_})
    end

    :ok
  end

  @doc """
  Dynamic children function for Entities sidebar tabs.

  Supports both arities:
  - `entities_children(scope, locale)` — preferred when phoenix_kit core
    (>= pending `dynamic_children/2` release) passes the current locale
    explicitly to the sidebar callback.
  - `entities_children(scope)` — fallback that reads the locale from
    `Gettext.get_locale/1`. Older core releases dispatch this form.
  """
  @spec entities_children(any(), String.t() | nil) :: [PhoenixKit.Dashboard.Tab.t()]
  @spec entities_children(any()) :: [PhoenixKit.Dashboard.Tab.t()]
  def entities_children(_scope, locale) when is_binary(locale) or is_nil(locale) do
    cached_entity_summaries(locale || Gettext.get_locale(PhoenixKitEntities.Gettext))
    |> build_entity_tabs()
  rescue
    _ -> []
  catch
    # On a cache miss this runs a live query, and the whole point of the
    # rescue is "an unreachable database degrades to an empty sidebar". An
    # unowned checkout raises, but a DEAD POOL EXITS — so without this the
    # guard did not hold in the case it exists for, and because core calls
    # this as its `dynamic_children` callback the exit took out every admin
    # page render. `enabled?/0` below already had the catch.
    :exit, _ -> []
  end

  def entities_children(_scope) do
    locale = Gettext.get_locale(PhoenixKitEntities.Gettext)

    cached_entity_summaries(locale)
    |> build_entity_tabs()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp build_entity_tabs(summaries) do
    summaries
    |> Enum.with_index()
    |> Enum.map(fn {entity, idx} ->
      %Tab{
        id:
          String.to_atom(
            "admin_entity_#{entity.name}_#{:erlang.phash2(entity.name) |> Integer.to_string(16) |> String.downcase()}"
          ),
        label: entity.display_name_plural || entity.display_name,
        icon: entity.icon || "hero-cube",
        path: "entities/#{entity.name}/data",
        priority: 541 + idx,
        level: :admin,
        permission: "entities",
        match: :prefix,
        parent: :admin_entities
      }
    end)
  end

  defp cached_entity_summaries(locale) do
    alias PhoenixKit.Dashboard.Registry, as: DashboardRegistry

    if DashboardRegistry.initialized?() do
      lookup_cached_entities(DashboardRegistry, locale)
    else
      list_entity_summaries(lang: locale)
    end
  end

  defp lookup_cached_entities(registry, locale) do
    cache_key = {@entities_cache_key, locale}

    case :ets.lookup(registry.ets_table(), cache_key) do
      [{^cache_key, entities, timestamp}] when is_integer(timestamp) ->
        if System.monotonic_time(:millisecond) - timestamp < @entities_cache_ttl_ms,
          do: entities,
          else: fetch_and_cache_entities(locale)

      _ ->
        fetch_and_cache_entities(locale)
    end
  end

  defp fetch_and_cache_entities(locale) do
    alias PhoenixKit.Dashboard.Registry, as: DashboardRegistry
    entities = list_entity_summaries(lang: locale)

    if DashboardRegistry.initialized?() do
      :ets.insert(
        DashboardRegistry.ets_table(),
        {{@entities_cache_key, locale}, entities, System.monotonic_time(:millisecond)}
      )
    end

    entities
  end

  @impl PhoenixKit.Module
  @spec settings_tabs() :: [PhoenixKit.Dashboard.Tab.t()]
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_entities,
        label: gettext_noop("Entities"),
        icon: "hero-cube",
        path: "entities",
        priority: 935,
        level: :admin,
        parent: :admin_settings,
        permission: "entities",
        match: :prefix,
        gettext_backend: PhoenixKitEntities.Gettext,
        gettext_domain: "default"
      )
    ]
  end

  @impl PhoenixKit.Module
  @spec children() :: [module()]
  def children, do: [PhoenixKitEntities.Presence]

  @spec css_sources() :: [atom()]
  def css_sources, do: [:phoenix_kit_entities]

  # Read from mix.exs at compile time rather than hardcoded, so this can never
  # drift from the package version again. It had: releases 0.3.0, 0.3.1 and
  # 0.3.2 all shipped reporting "0.2.10".
  @version Mix.Project.config()[:version]

  @impl PhoenixKit.Module
  @spec version() :: String.t()
  def version, do: @version

  @impl PhoenixKit.Module
  @spec route_module() :: module()
  def route_module, do: PhoenixKitEntities.Routes

  @impl PhoenixKit.Module
  @spec sitemap_sources() :: [module()]
  def sitemap_sources, do: [PhoenixKitEntities.SitemapSource]

  # ============================================================================
  # Sort Mode Settings
  # ============================================================================

  @valid_sort_modes ~w(auto manual)

  @doc """
  Gets the sort mode for an entity.

  Returns `"auto"` (sort by creation date, default) or `"manual"` (sort by position).

  ## Examples

      iex> PhoenixKitEntities.get_sort_mode(entity)
      "auto"
  """
  @spec get_sort_mode(t()) :: String.t()
  def get_sort_mode(%__MODULE__{settings: settings}) do
    (settings || %{}) |> Map.get("sort_mode", "auto")
  end

  @doc """
  Gets the sort mode for an entity by UUID.

  Convenience wrapper that looks up the entity first.
  Returns `"auto"` if the entity is not found.

  ## Examples

      iex> PhoenixKitEntities.get_sort_mode_by_uuid(entity_uuid)
      "manual"
  """
  @spec get_sort_mode_by_uuid(binary()) :: String.t()
  def get_sort_mode_by_uuid(entity_uuid) when is_binary(entity_uuid) do
    case get_entity(entity_uuid) do
      nil -> "auto"
      entity -> get_sort_mode(entity)
    end
  end

  @doc """
  Checks if an entity uses manual sorting.

  ## Examples

      iex> PhoenixKitEntities.manual_sort?(entity)
      true
  """
  @spec manual_sort?(t()) :: boolean()
  def manual_sort?(%__MODULE__{} = entity), do: get_sort_mode(entity) == "manual"

  @doc """
  Updates the sort mode for an entity.

  Valid modes: `"auto"` (sort by creation date) or `"manual"` (sort by position).

  When switching to manual mode, existing records retain their auto-populated
  positions from creation order. Admins can then reorder as needed.

  ## Examples

      iex> PhoenixKitEntities.update_sort_mode(entity, "manual")
      {:ok, %PhoenixKitEntities{}}
  """
  @spec update_sort_mode(t(), String.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update_sort_mode(%__MODULE__{} = entity, mode) when mode in @valid_sort_modes do
    current_settings = entity.settings || %{}
    new_settings = Map.put(current_settings, "sort_mode", mode)
    update_entity(entity, %{settings: new_settings})
  end

  # ============================================================================
  # Per-Entity Mirror Settings
  # ============================================================================

  @doc """
  Gets the mirror settings for an entity.

  Returns a map with mirror_definitions and mirror_data booleans.
  Defaults to false if not explicitly set.

  ## Examples

      iex> PhoenixKitEntities.get_mirror_settings(entity)
      %{mirror_definitions: true, mirror_data: false}
  """
  @spec get_mirror_settings(t()) :: %{mirror_definitions: boolean(), mirror_data: boolean()}
  def get_mirror_settings(%__MODULE__{settings: settings}) do
    settings = settings || %{}

    %{
      mirror_definitions: Map.get(settings, "mirror_definitions", false),
      mirror_data: Map.get(settings, "mirror_data", false)
    }
  end

  @doc """
  Checks if definition mirroring is enabled for this entity.

  ## Examples

      iex> PhoenixKitEntities.mirror_definitions_enabled?(entity)
      true
  """
  @spec mirror_definitions_enabled?(t()) :: boolean()
  def mirror_definitions_enabled?(%__MODULE__{settings: settings}) do
    settings = settings || %{}
    Map.get(settings, "mirror_definitions", false) == true
  end

  @doc """
  Checks if data mirroring is enabled for this entity.

  ## Examples

      iex> PhoenixKitEntities.mirror_data_enabled?(entity)
      false
  """
  @spec mirror_data_enabled?(t()) :: boolean()
  def mirror_data_enabled?(%__MODULE__{settings: settings}) do
    settings = settings || %{}
    Map.get(settings, "mirror_data", false) == true
  end

  @doc """
  Updates the mirror settings for an entity.

  ## Parameters
    - `entity` - The entity to update
    - `mirror_settings` - Map with keys "mirror_definitions" and/or "mirror_data"

  ## Examples

      iex> PhoenixKitEntities.update_mirror_settings(entity, %{"mirror_definitions" => true})
      {:ok, %PhoenixKit.Entities{}}
  """
  @spec update_mirror_settings(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update_mirror_settings(%__MODULE__{} = entity, mirror_settings)
      when is_map(mirror_settings) do
    current_settings = entity.settings || %{}
    new_settings = Map.merge(current_settings, mirror_settings)
    update_entity(entity, %{settings: new_settings})
  end

  # ============================================================================
  @doc """
  Lists all entities with their mirror status and data counts.

  Returns a list of maps suitable for the settings UI.

  ## Examples

      iex> PhoenixKitEntities.list_entities_with_mirror_status()
      [%{id: 1, name: "test", display_name: "Test", data_count: 8, mirror_definitions: true, mirror_data: false}, ...]
  """
  @spec list_entities_with_mirror_status() :: [map()]
  def list_entities_with_mirror_status do
    entities = list_entities()

    # One grouped count for the whole list rather than one per entity.
    # `EntityData.counts_by_entities/2` already existed for exactly this and
    # simply was not used here — and the settings LiveView re-runs this
    # function on EVERY entity and data broadcast, so a user typing in a
    # record (autosave emits :data_updated per debounced keystroke) drove
    # 1 + N counts plus N filesystem stats on every open settings page.
    counts = EntityData.counts_by_entities(Enum.map(entities, & &1.uuid))
    mirrored_files = MapSet.new(Storage.list_entities())

    Enum.map(entities, fn entity ->
      mirror_settings = get_mirror_settings(entity)
      data_count = Map.get(counts, entity.uuid, 0)
      file_exists = MapSet.member?(mirrored_files, entity.name)

      %{
        uuid: entity.uuid,
        name: entity.name,
        display_name: entity.display_name,
        data_count: data_count,
        mirror_definitions: mirror_settings.mirror_definitions,
        mirror_data: mirror_settings.mirror_data,
        file_exists: file_exists
      }
    end)
  end

  @doc """
  Enables definition mirroring for all entities.

  ## Examples

      iex> PhoenixKitEntities.enable_all_definitions_mirror()
      {:ok, count}
  """
  @spec enable_all_definitions_mirror() :: {:ok, non_neg_integer()}
  def enable_all_definitions_mirror do
    entities = list_entities()

    results =
      Enum.map(entities, fn entity ->
        update_mirror_settings(entity, %{"mirror_definitions" => true})
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    {:ok, success_count}
  end

  @doc """
  Disables definition mirroring for all entities.

  ## Examples

      iex> PhoenixKitEntities.disable_all_definitions_mirror()
      {:ok, count}
  """
  @spec disable_all_definitions_mirror() :: {:ok, non_neg_integer()}
  def disable_all_definitions_mirror do
    entities = list_entities()

    results =
      Enum.map(entities, fn entity ->
        update_mirror_settings(entity, %{"mirror_definitions" => false})
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    {:ok, success_count}
  end

  @doc """
  Enables data mirroring for all entities.

  ## Examples

      iex> PhoenixKitEntities.enable_all_data_mirror()
      {:ok, count}
  """
  @spec enable_all_data_mirror() :: {:ok, non_neg_integer()}
  def enable_all_data_mirror do
    entities = list_entities()

    results =
      Enum.map(entities, fn entity ->
        update_mirror_settings(entity, %{"mirror_data" => true})
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    {:ok, success_count}
  end

  @doc """
  Disables data mirroring for all entities.

  ## Examples

      iex> PhoenixKitEntities.disable_all_data_mirror()
      {:ok, count}
  """
  @spec disable_all_data_mirror() :: {:ok, non_neg_integer()}
  def disable_all_data_mirror do
    entities = list_entities()

    results =
      Enum.map(entities, fn entity ->
        update_mirror_settings(entity, %{"mirror_data" => false})
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    {:ok, success_count}
  end

  # ============================================================================
  # Translation convenience API
  # ============================================================================

  @doc """
  Gets all translations for an entity definition.

  Returns a map of language codes to translated fields.
  Only includes languages that have at least one translated field.

  ## Examples

      iex> get_entity_translations(entity)
      %{
        "es-ES" => %{"display_name" => "Productos", "display_name_plural" => "Productos"},
        "fr-FR" => %{"display_name" => "Produits"}
      }

      iex> get_entity_translations(entity_without_translations)
      %{}
  """
  @spec get_entity_translations(t()) :: %{optional(String.t()) => map()}
  def get_entity_translations(%__MODULE__{settings: settings}) do
    (settings || %{})
    |> Map.get("translations", %{})
  end

  @doc """
  Gets the translation for a specific language on an entity definition.

  Returns the translated fields merged with the primary language values
  as defaults. Returns primary language values if no translation exists.

  ## Examples

      iex> get_entity_translation(entity, "es-ES")
      %{"display_name" => "Productos", "display_name_plural" => "Productos", "description" => "..."}
  """
  @spec get_entity_translation(t(), String.t()) :: map() | nil
  def get_entity_translation(%__MODULE__{} = entity, lang_code) when is_binary(lang_code) do
    primary = %{
      "display_name" => entity.display_name,
      "display_name_plural" => entity.display_name_plural,
      "description" => entity.description
    }

    translations = get_entity_translations(entity)
    lang_overrides = lookup_translation(translations, lang_code)

    Map.merge(primary, lang_overrides)
  end

  @doc """
  Sets the translation for a specific language on an entity definition.

  Merges the provided fields into the existing translation for that language.
  Empty string values are treated as "remove override" (field falls back to primary).

  ## Examples

      iex> set_entity_translation(entity, "es-ES", %{
      ...>   "display_name" => "Productos",
      ...>   "display_name_plural" => "Productos"
      ...> })
      {:ok, %PhoenixKitEntities{}}
  """
  @spec set_entity_translation(t(), String.t(), map()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def set_entity_translation(%__MODULE__{} = entity, lang_code, attrs)
      when is_binary(lang_code) and is_map(attrs) do
    current_settings = entity.settings || %{}
    translations = Map.get(current_settings, "translations", %{})

    existing = Map.get(translations, lang_code, %{})
    merged = Map.merge(existing, attrs)

    # Remove empty values (fall back to primary)
    cleaned =
      merged
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    updated_translations =
      if map_size(cleaned) == 0 do
        Map.delete(translations, lang_code)
      else
        Map.put(translations, lang_code, cleaned)
      end

    new_settings =
      if map_size(updated_translations) == 0 do
        Map.delete(current_settings, "translations")
      else
        Map.put(current_settings, "translations", updated_translations)
      end

    update_entity(entity, %{settings: new_settings})
  end

  @doc """
  Removes all translations for a specific language from an entity definition.

  ## Examples

      iex> remove_entity_translation(entity, "es-ES")
      {:ok, %PhoenixKitEntities{}}
  """
  @spec remove_entity_translation(t(), String.t()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def remove_entity_translation(%__MODULE__{} = entity, lang_code)
      when is_binary(lang_code) do
    current_settings = entity.settings || %{}
    translations = Map.get(current_settings, "translations", %{})
    updated = Map.delete(translations, lang_code)

    new_settings =
      if map_size(updated) == 0 do
        Map.delete(current_settings, "translations")
      else
        Map.put(current_settings, "translations", updated)
      end

    update_entity(entity, %{settings: new_settings})
  end

  @doc """
  Checks if multilang is globally enabled (Languages module has 2+ languages).

  Convenience wrapper around `Multilang.enabled?/0`.

  ## Examples

      iex> PhoenixKitEntities.multilang_enabled?()
      true
  """
  @spec multilang_enabled?() :: boolean()
  def multilang_enabled?, do: Multilang.enabled?()

  # ============================================================================
  # Language-aware API
  # ============================================================================

  @doc """
  Resolves translated fields on an entity struct for a given language.

  Merges translations from `settings["translations"][lang_code]` onto the
  entity's `display_name`, `display_name_plural`, and `description` fields.

  For the primary language (or when no translation exists), returns the entity
  unchanged. For secondary languages, applies override values where they exist
  and keeps primary values as defaults.

  ## Examples

      iex> resolve_language(entity, "es-ES")
      %PhoenixKitEntities{display_name: "Productos", ...}

      iex> resolve_language(entity, "en-US")  # primary language
      %PhoenixKitEntities{display_name: "Products", ...}
  """
  @spec resolve_language(t(), String.t() | nil) :: t()
  def resolve_language(entity, nil), do: entity

  @spec resolve_language(t(), String.t()) :: t()
  def resolve_language(%__MODULE__{} = entity, lang_code) when is_binary(lang_code) do
    translation = get_entity_translation(entity, lang_code)

    entity
    |> maybe_apply_translation(:display_name, translation["display_name"])
    |> maybe_apply_translation(:display_name_plural, translation["display_name_plural"])
    |> maybe_apply_translation(:description, translation["description"])
  end

  defp maybe_apply_translation(entity, _field, nil), do: entity
  defp maybe_apply_translation(entity, _field, ""), do: entity

  defp maybe_apply_translation(entity, field, value) do
    Map.put(entity, field, value)
  end

  @doc """
  Resolves translations on a list of entity structs.

  ## Examples

      iex> resolve_languages(entities, "es-ES")
      [%PhoenixKitEntities{display_name: "Productos"}, ...]
  """
  @spec resolve_languages([t()], String.t() | nil) :: [t()]
  def resolve_languages(entities, nil), do: entities

  @spec resolve_languages([t()], String.t()) :: [t()]
  def resolve_languages(entities, lang_code) when is_list(entities) and is_binary(lang_code) do
    Enum.map(entities, &resolve_language(&1, lang_code))
  end

  @doc false
  @spec maybe_resolve_lang(t(), keyword()) :: t()
  def maybe_resolve_lang(entity, opts) when is_list(opts) do
    case Keyword.get(opts, :lang) do
      nil -> entity
      lang -> resolve_language(entity, lang)
    end
  end

  # Applies :lang option to a list of entities if present in opts
  defp maybe_resolve_langs(entities, opts) when is_list(entities) and is_list(opts) do
    case Keyword.get(opts, :lang) do
      nil -> entities
      lang -> resolve_languages(entities, lang)
    end
  end

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
