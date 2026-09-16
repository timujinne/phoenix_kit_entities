defmodule PhoenixKitEntities.Managed do
  @moduledoc """
  Support for MANAGED entity blueprints — blueprints owned by another
  module (e.g. the catalogue's attribute sets), created and administered
  exclusively through that module's own UI on top of the entities API.

  A managed blueprint carries in its `settings`:

      "managed_by"  => "catalogue"          # owning module key
      "locked_keys" => ["kind", ...]        # settings["<owner>"] keys the
                                            # generic write path must not touch

  ## The two guarantees

  1. **Hidden from the generic admin** — `managed?/1` lets listings
     exclude these blueprints (`PhoenixKitEntities.list_entities/1`
     accepts `include_managed: false`); the owning module renders its
     own management UI.
  2. **Write-path protection** — `validate_mutation/2` and
     `validate_delete/1` are called by the entities write path (not just
     the UI): mutations from anywhere but the owning module cannot
     rename the blueprint's slug, change its status, or touch locked
     settings keys; deletion requires the owner's confirmation callback
     to approve (e.g. the catalogue refuses while item attachments
     exist). UI guards without a write interceptor are theater.
     One write path is deliberately outside the interception:
     `reorder_entities/2` bulk-updates `position` via `update_all`, and
     `position` is not part of any owner contract. The same theater
     risk applies one level down: `validate_data_mutation/4` protects a
     DATA RECORD's `slug` the same way, since the owner's own tables key
     relations on it (e.g. the catalogue's `selected_value_slugs`) — every
     other data-record field is unguarded and goes through the ordinary
     `EntityData` write path untouched.

  Owners bypass the guard by passing `on_behalf_of: "<owner>"` in opts —
  the guard is against *accidental* generic-admin edits, not a security
  boundary (all callers are admin code).

  ## Delete approval

  Owners register a delete-approval callback at runtime:

      PhoenixKitEntities.Managed.register_delete_guard(
        "catalogue",
        &MyApp.Catalogue.deletion_guard/1
      )

  where `deletion_guard/1` returns `:ok` or `{:error, reason}` (e.g.
  `{:error, :set_in_use}` while item attachments exist). The callback
  MUST be an external capture (`&Mod.fun/1`), never an anonymous fun: a
  local capture in `:persistent_term` goes stale when the registering
  module is purged (code reload / hot upgrade), raises on call, and
  every delete then fails closed with `{:error, :delete_guard_error}`.

  Registration is process-independent (persistent_term), set up in the
  owning module's application start. A managed blueprint with no
  registered guard refuses deletion outright — fail closed.

  ## Known gaps — value records (blueprint guards above are complete)

  - **Creation is unguarded.** `EntityData.create/2` never consults this
    module, so a generic caller can create a value record under a managed
    blueprint with a duplicate `slug` freely — there is no unique index on
    `(entity_uuid, slug)` either. This is the direct, accepted consequence
    of the CREATE-path deviation documented on `validate_data_mutation/4`:
    the slug field is deliberately unlocked on `/data/new` (there is no
    prior slug to protect there yet), and nothing closes the write path
    to match.
  - **Deletion is unguarded.** There is no data-record analogue of
    `validate_delete/1` above: `EntityData.trash/2` and `EntityData.delete/2`
    both succeed on a record whose blueprint is managed, and the generic
    admin (`web/data_navigator.ex`, "Delete forever" / trash) offers both
    actions on these rows with no `managed` check at all.

  Both are scope decisions, not oversights (2026-09-11 review, MAJOR-2 /
  MAJOR-3) — the design puts the safety net on the owner's side instead
  (a subscriber that prunes dangling `slug` references on the
  `:data_deleted` PubSub event — see `EntityData.delete/2` and
  `EntityData.bulk_delete/2`). Closing either gap here would need a
  maintainer decision on where a create/delete write-path guard for
  value records belongs, not just a mechanical addition.
  """

  # One :persistent_term key per owner, not one shared map: owners register
  # from their own boot tasks, often at the same moment, and a shared map's
  # read-modify-write let a later registration drop an earlier owner's guard
  # (every delete of that owner's blueprints then failed closed with
  # :no_delete_guard). Each owner now writes only its own key.
  defp guard_key(owner), do: {__MODULE__, :delete_guard, owner}

  @doc "True when the entity is managed by another module."
  @spec managed?(struct() | map()) :: boolean()
  def managed?(%{settings: settings}) when is_map(settings),
    do: is_binary(settings["managed_by"])

  def managed?(_), do: false

  @doc "The owning module key, or nil."
  @spec owner(struct() | map()) :: String.t() | nil
  def owner(%{settings: settings}) when is_map(settings), do: settings["managed_by"]
  def owner(_), do: nil

  @doc """
  Validates an update to `entity` with `attrs`. Returns `:ok` or
  `{:error, reason}`. Owner-originated calls (`on_behalf_of` matching
  the owner) pass unconditionally.
  """
  @spec validate_mutation(struct(), map(), keyword()) ::
          :ok | {:error, :managed_blueprint | :locked_key}
  def validate_mutation(entity, attrs, opts \\ []) do
    cond do
      # Acquisition first: an update that ADDS markers to a previously
      # unmanaged blueprint is the create-then-update masquerade — the
      # `not managed?` short-circuit below reads the OLD settings and
      # would wave it through (panel finding, 2026-08-19 review).
      acquires_markers?(entity, attrs, opts) -> {:error, :managed_blueprint}
      not managed?(entity) -> :ok
      Keyword.get(opts, :on_behalf_of) == owner(entity) -> :ok
      renames_identity?(entity, attrs) -> {:error, :managed_blueprint}
      tampers_with_markers?(entity, attrs) -> {:error, :managed_blueprint}
      touches_locked_keys?(entity, attrs) -> {:error, :locked_key}
      true -> :ok
    end
  end

  @doc """
  Validates CREATING an entity with `attrs`: a blueprint claiming a
  `managed_by` owner can only be provisioned by that owner
  (`on_behalf_of` matching). Without this, any generic caller could
  create a blueprint that masquerades as module-owned — hidden from
  the generic admin yet picked up by the owning module's listings
  (panel finding, 2026-08-18 review).
  """
  @spec validate_creation(map(), keyword()) :: :ok | {:error, :managed_blueprint}
  def validate_creation(attrs, opts \\ []) do
    case claimed_owner(attrs) do
      nil ->
        :ok

      claimed when is_binary(claimed) ->
        if Keyword.get(opts, :on_behalf_of) == claimed,
          do: :ok,
          else: {:error, :managed_blueprint}
    end
  end

  @doc """
  Validates an update to a DATA RECORD belonging to `owning_entity` — the
  blueprint the record's `entity_uuid` points at. A managed blueprint's
  owner keys its own relations on a value record's `slug` (e.g. the
  catalogue's `selected_value_slugs`), so a generic caller changing it
  would silently break that relation — the write path refuses it here
  rather than trusting the UI guard alone (see moduledoc). Owner-originated
  calls (`on_behalf_of` matching the owner) pass unconditionally — the
  owner may repoint its own relation. `data_record` supplies the slug's
  PRIOR value: resubmitting a form with the field disabled still posts the
  unchanged slug back (so validation and this guard both see a whole
  payload), and that must not read as a rename.

  Re-pointing the record at another blueprint (`entity_uuid`) is guarded
  the same way as a slug rename — see `moves_data_record?/2` — since it
  detaches the record from the owner's set just as thoroughly. A
  secondary language's `_slug` override inside `data` is guarded the
  same way too — see `renames_translated_slug?/2`.

  Only the record's `slug`, `entity_uuid`, and any per-language `_slug`
  override are protected — `title`, `status`, and everything else in
  `data` go through unguarded, same as for an unmanaged blueprint's
  records.

  `owning_entity` is trusted to actually be the blueprint `data_record`
  belongs to — every real caller resolves it from `data_record.entity_uuid`
  right before calling this. If the two disagree (both carry a uuid and
  they differ), this refuses the mutation rather than deciding
  `managed?/1` off a blueprint that isn't the record's own: passing an
  unrelated, UNMANAGED blueprint here would otherwise let the first
  `cond` clause below wave the mutation through without ever consulting
  the record's real owner.
  """
  @spec validate_data_mutation(struct() | nil, struct(), map(), keyword()) ::
          :ok | {:error, :locked_key}
  def validate_data_mutation(owning_entity, data_record, attrs, opts \\ []) do
    # Any clause added below that guards a new field must also be added
    # to `data_mutation_needs_owner?/2` right below — see its @doc.
    cond do
      mismatched_owner?(owning_entity, data_record) -> {:error, :locked_key}
      not managed?(owning_entity) -> :ok
      Keyword.get(opts, :on_behalf_of) == owner(owning_entity) -> :ok
      renames_data_slug?(data_record, attrs) -> {:error, :locked_key}
      renames_translated_slug?(data_record, attrs) -> {:error, :locked_key}
      moves_data_record?(data_record, attrs) -> {:error, :locked_key}
      true -> :ok
    end
  end

  # MINOR-4 (2026-09-11 review): only flags a mismatch when BOTH uuids
  # are present and differ, so a nil `owning_entity` (dangling
  # entity_uuid — treated as unmanaged, see `not managed?/1` above) and
  # every existing test's plain-map fixtures (which don't set `:uuid` /
  # `:entity_uuid` at all) are untouched. A REAL caller always resolves
  # `owning_entity` from `data_record.entity_uuid`, so the two uuids can
  # never legitimately disagree; a mismatch only happens when a caller
  # passes the wrong blueprint, which is a bug this fails closed against
  # rather than trusts.
  defp mismatched_owner?(nil, _data_record), do: false

  defp mismatched_owner?(owning_entity, data_record) do
    entity_uuid = Map.get(data_record, :entity_uuid)
    owning_uuid = Map.get(owning_entity, :uuid)

    is_binary(entity_uuid) and is_binary(owning_uuid) and entity_uuid != owning_uuid
  end

  @doc """
  True when `attrs` touches a field `validate_data_mutation/4` guards —
  today, any of `renames_data_slug?/2`, `renames_translated_slug?/2`, or
  `moves_data_record?/2`.

  `EntityData.validate_managed_slug/3` calls this FIRST to decide whether
  an ordinary save is even worth the owning-entity lookup (a `SELECT`
  plus `preload(:creator)`) that `validate_data_mutation/4` would
  otherwise need before it could return `:ok` for an unmanaged blueprint
  or a save that touches none of the guarded fields. Deliberately kept
  beside `validate_data_mutation/4`'s `cond` rather than in `EntityData`:
  a clause added there for a newly guarded field belongs here too, in
  the same module, in the same diff.
  """
  @spec data_mutation_needs_owner?(struct(), map()) :: boolean()
  def data_mutation_needs_owner?(data_record, attrs) do
    renames_data_slug?(data_record, attrs) or
      renames_translated_slug?(data_record, attrs) or
      moves_data_record?(data_record, attrs)
  end

  @doc """
  Validates deleting `entity`. Owner-originated calls consult nothing;
  generic calls are refused; the owner's registered guard arbitrates
  owner-side deletes.
  """
  @spec validate_delete(struct(), keyword()) :: :ok | {:error, term()}
  def validate_delete(entity, opts \\ []) do
    cond do
      not managed?(entity) ->
        :ok

      Keyword.get(opts, :on_behalf_of) != owner(entity) ->
        {:error, :managed_blueprint}

      true ->
        case delete_guard(owner(entity)) do
          nil -> {:error, :no_delete_guard}
          fun -> run_delete_guard(fun, entity)
        end
    end
  end

  # A guard that raises must FAIL CLOSED, not propagate: the classic
  # cause is a stale local-fun capture in :persistent_term after the
  # registering module was purged (code reload / hot upgrade) — owners
  # must register EXTERNAL captures (`&Mod.fun/1`), but a blueprint
  # delete must never crash the caller either way.
  defp run_delete_guard(fun, entity) do
    case fun.(entity) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_guard_result, other}}
    end
  rescue
    _ -> {:error, :delete_guard_error}
  catch
    # A guard whose DB call exits (e.g. connection owner death) must
    # fail closed the same way a raise does.
    :exit, _ -> {:error, :delete_guard_error}
  end

  @doc """
  Registers (replaces) the owner's delete-approval callback.

  Safe to call from concurrent boot tasks: each owner's guard lives under its
  own key, so one owner's registration never touches another's.
  """
  @spec register_delete_guard(String.t(), (struct() -> :ok | {:error, term()})) :: :ok
  def register_delete_guard(owner, fun) when is_binary(owner) and is_function(fun, 1) do
    :persistent_term.put(guard_key(owner), fun)
  end

  defp delete_guard(owner), do: :persistent_term.get(guard_key(owner), nil)

  # The owner a settings payload claims via "managed_by", or nil. Ecto's
  # :map type stores whatever key kind it is given and the JSONB encoder
  # writes atom keys out as strings — so an atom-keyed
  # %{managed_by: "catalogue"} would persist as a managed blueprint while
  # a string-only lookup here reads nil and fails OPEN. Check both key
  # forms (panel finding, 2026-08-19 review).
  defp claimed_owner(attrs) do
    settings = attrs[:settings] || attrs["settings"]

    if is_map(settings) do
      case Map.get(settings, "managed_by") || Map.get(settings, :managed_by) do
        claimed when is_binary(claimed) -> claimed
        _ -> nil
      end
    else
      nil
    end
  end

  # True when an update to an UNMANAGED blueprint would stamp a
  # "managed_by" claim the caller isn't entitled to.
  defp acquires_markers?(entity, attrs, opts) do
    not managed?(entity) and
      case claimed_owner(attrs) do
        nil -> false
        claimed -> Keyword.get(opts, :on_behalf_of) != claimed
      end
  end

  # Identity/status: the slug (`name`) and `status` are part of the
  # owner's contract — other modules reference the blueprint by them.
  defp renames_identity?(entity, attrs) do
    new_name = attrs[:name] || attrs["name"]
    new_status = attrs[:status] || attrs["status"]

    (is_binary(new_name) and new_name != entity.name) or
      (is_binary(new_status) and new_status != entity.status)
  end

  @doc """
  True when `attrs` supplies a `:slug` (or `"slug"`) that differs from
  `data_record.slug` — the relation key a managed blueprint's owner keys
  on (e.g. catalogue's `selected_value_slugs`), same rationale as
  `renames_identity?/2` above, one level down at the data-record layer.

  Presence, not truthiness, decides whether `attrs` even speaks to the
  slug: `Map.fetch/2` (not `attrs[:slug] || attrs["slug"]`), so an
  explicit `slug: nil` reads as a change instead of silently passing as
  "not binary, therefore untouched" and erasing the slug — closing that
  off for any caller that ever builds `attrs` from a source where the
  key can be present-but-nil (`mirror/importer.ex`'s own record-matching
  guard happens to keep the key aligned with the existing slug today,
  but this function doesn't get to assume that of every caller). A key
  simply ABSENT from `attrs` is still not a rename: an ordinary
  title/data save never mentions `:slug` at all.

  `""` and `nil` are the same "no slug" on both sides of the compare:
  the disabled field's hidden mirror posts back `""` when the DATABASE
  value is already `nil` (a record created before the UI stopped
  locking the field on `/data/new`, back-filled or otherwise) — Ecto's
  own `cast/4` would fold that `""` to `nil` too, so failing to close
  here made that resubmit read as a rename of a title-only save.

  Public so `EntityData.update/3` can call it directly, ahead of
  `validate_data_mutation/4`: when this returns `false`, that function
  would return `:ok` no matter what the owning entity turns out to be,
  so there is no reason to pay for looking it up first.
  """
  @spec renames_data_slug?(struct(), map()) :: boolean()
  def renames_data_slug?(data_record, attrs) do
    case fetch_slug(attrs) do
      :error -> false
      {:ok, new_slug} -> normalize_slug(new_slug) != normalize_slug(data_record.slug)
    end
  end

  defp fetch_slug(attrs) do
    case Map.fetch(attrs, :slug) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, "slug")
    end
  end

  defp normalize_slug(""), do: nil
  defp normalize_slug(slug), do: slug

  @doc """
  True when `attrs` supplies an `:entity_uuid` (or `"entity_uuid"`) that
  differs from `data_record.entity_uuid` — re-pointing a value record at
  another blueprint. This detaches the record from the owner's set
  exactly as thoroughly as renaming its `slug` does (`renames_data_slug?/2`):
  the owner's `list_values_for/1` stops returning it, and its slug becomes
  a ghost in whatever relation keys on it (e.g. the catalogue's
  `selected_value_slugs`), because `list_values_for/1` filters by
  `entity_uuid`, not by `slug`.

  Presence-based like `renames_data_slug?/2`, for the same reason: an
  explicit `entity_uuid: nil` reads as a move, not a no-op.
  """
  @spec moves_data_record?(struct(), map()) :: boolean()
  def moves_data_record?(data_record, attrs) do
    case fetch_entity_uuid(attrs) do
      :error -> false
      {:ok, new_entity_uuid} -> new_entity_uuid != Map.get(data_record, :entity_uuid)
    end
  end

  defp fetch_entity_uuid(attrs) do
    case Map.fetch(attrs, :entity_uuid) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, "entity_uuid")
    end
  end

  @doc """
  True when `attrs["data"]` (or `:data`) changes any language's `"_slug"`
  override away from what `data_record.data` already has for that
  language — the secondary-language mirror of `renames_data_slug?/2`, one
  level down inside the JSONB `data` column (multilang stores per-language
  overrides at `data[lang]["_slug"]`, see `PhoenixKit.Utils.Multilang`).
  `web/data_form.ex`'s `translatable_field` disables this input on a
  secondary tab for the same reason it disables the primary slug field,
  but a LiveView event is not bound by that markup — same class of gap as
  `generate_slug` (see `do_generate_slug/1`'s guard).

  A language absent from `attrs["data"]`, or present without a `"_slug"`
  key, is not a rename — multilang only stores overrides, so most
  languages never carry their own `"_slug"` at all.

  The PRIMARY language is compared against the `slug` column when the
  stored row has no primary `"_slug"`: the multilang form injects the
  column's value there on every save, and that resubmit is not a rename.
  """
  @spec renames_translated_slug?(struct(), map()) :: boolean()
  def renames_translated_slug?(data_record, attrs) do
    case fetch_data(attrs) do
      {:ok, new_data} when is_map(new_data) ->
        old_data = Map.get(data_record, :data)
        old_data = if is_map(old_data), do: old_data, else: %{}
        primary = old_data["_primary_language"] || new_data["_primary_language"]

        Enum.any?(new_data, fn
          {lang, %{"_slug" => new_slug}} when is_binary(lang) ->
            old_slug = stored_lang_slug(data_record, old_data, lang, primary)
            normalize_slug(new_slug) != normalize_slug(old_slug)

          _ ->
            false
        end)

      _ ->
        false
    end
  end

  # The primary language's `_slug` mirrors the `slug` column: the data form
  # seeds it from the column on mount and injects it on every multilang
  # save. A row that never stored its own primary `_slug` (anything created
  # through `EntityData.create/2` with only `slug` set) is still keyed on
  # the column, so that is the value a resubmit has to match.
  defp stored_lang_slug(data_record, old_data, lang, primary) do
    case get_in(old_data, [lang, "_slug"]) do
      nil when lang == primary -> Map.get(data_record, :slug)
      old_slug -> old_slug
    end
  end

  defp fetch_data(attrs) do
    case Map.fetch(attrs, :data) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, "data")
    end
  end

  # The marker keys ARE the protection — a generic settings write that
  # rewrites or drops "managed_by"/"locked_keys" would un-manage the
  # blueprint (or unlock everything) and then walk straight past every
  # other guard (panel finding, 2026-08-18 review). Only settings-bearing
  # updates are checked: an update without :settings can't touch them.
  defp tampers_with_markers?(entity, attrs) do
    new_settings = attrs[:settings] || attrs["settings"]

    if is_map(new_settings) do
      old_settings = entity.settings || %{}

      new_settings["managed_by"] != old_settings["managed_by"] or
        new_settings["locked_keys"] != old_settings["locked_keys"]
    else
      false
    end
  end

  # Locked keys live under settings["<owner>"] — reject any update whose
  # settings change them. Adding NEW keys (or fields_definition changes)
  # stays allowed: extra value fields are the whole point.
  defp touches_locked_keys?(entity, attrs) do
    new_settings = attrs[:settings] || attrs["settings"]

    if is_map(new_settings) do
      owner_key = owner(entity)
      locked = List.wrap((entity.settings || %{})["locked_keys"])
      old_owner_settings = (entity.settings || %{})[owner_key] || %{}
      new_owner_settings = new_settings[owner_key] || %{}

      Enum.any?(locked, fn key ->
        Map.get(new_owner_settings, key) != Map.get(old_owner_settings, key)
      end)
    else
      false
    end
  end
end
