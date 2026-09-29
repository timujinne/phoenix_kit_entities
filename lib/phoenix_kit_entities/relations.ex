defmodule PhoenixKitEntities.Relations do
  @moduledoc """
  The `relation` field type: a record that links to records of another
  entity (a panel size that is sold in a set of grades, say).

  ## Field definition

      %{
        "type" => "relation",
        "key" => "grades",
        "label" => "Grades",
        "target_entity" => "0199…",   # the target entity's uuid (or its name)
        "allow_multiple" => true
      }

  `target_entity` is stored as the target entity's uuid, which survives a
  rename; a name is accepted too, for definitions written by hand or in
  seeds. `allow_multiple` picks the stored shape.

  ## Stored value

  The linked record's uuid (single) or a list of uuids (multiple), in
  `data[key]`. A link is the same in every language, so it lives only in
  the primary language's data; `EntityData.changeset/2` drops any copy
  that lands under a secondary language.

  ## Rules

    * A write may only ADD a uuid that is a record of the target entity
      and not in the trash. Links a record already holds are left alone,
      so a target that was trashed (or whose entity went away) never
      blocks saving the record that points at it.
    * Reads (`resolve/3`, the admin views) skip links whose target is
      missing or trashed. Trashing a target keeps the link, so restoring
      it brings the link back.
    * Deleting a target permanently removes its uuid from every record
      that links to it (`prune_deleted/1`, run inside the delete). A save
      from a copy of the record loaded before that delete does not bring
      the link back (`check_references/4`).

  Nothing here renders; `FormBuilder` draws the picker from the context
  `picker_contexts/3` builds.
  """

  import Ecto.Query, warn: false

  use Gettext, backend: PhoenixKitEntities.Gettext

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Events
  alias PhoenixKitEntities.Mirror.Exporter

  @soft_delete_status "trashed"

  # A target with at most this many live records gets a checkbox list (or
  # a select); a bigger one gets a search box.
  @list_limit 50

  @doc "The live-record count up to which the admin picker lists every target record."
  @spec list_limit() :: pos_integer()
  def list_limit, do: @list_limit

  # ── Field helpers ────────────────────────────────────────────────

  @doc "Is this field definition a relation?"
  @spec relation?(term()) :: boolean()
  def relation?(%{"type" => "relation"}), do: true
  def relation?(_), do: false

  @doc """
  Does the field hold a list of links? Tolerates the string `"true"` a
  form checkbox submits.
  """
  @spec multiple?(map()) :: boolean()
  def multiple?(field) when is_map(field), do: field["allow_multiple"] in [true, "true"]

  @doc "The relation fields of an entity (or of a fields definition list)."
  @spec relation_fields(map() | list() | nil) :: [map()]
  def relation_fields(%{fields_definition: fields}), do: relation_fields(fields)
  def relation_fields(fields) when is_list(fields), do: Enum.filter(fields, &relation?/1)
  def relation_fields(_), do: []

  @doc """
  Whether the `entities_allow_relations` setting lets admins add NEW
  relation fields (default `true`). Fields that already exist keep
  working either way.
  """
  @spec allowed?() :: boolean()
  def allowed? do
    Settings.get_boolean_setting("entities_allow_relations", true)
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  # ── Values (no database) ─────────────────────────────────────────

  @doc """
  The uuids a stored or submitted value names, in order, without
  duplicates. Anything that is not a uuid string is left out.
  """
  @spec uuids(term()) :: [String.t()]
  def uuids(value) do
    value
    |> List.wrap()
    |> Enum.filter(&uuid?/1)
    |> Enum.uniq()
  end

  @doc """
  Checks a value's shape against the field and returns the canonical
  form: `nil` or a uuid for a single link, a list of uuids for a
  multiple one. Does not touch the database — `check_references/3` does
  that.

  Lenient where a caller's intent is plain: `""` and `[""]` (what an
  empty form control submits) mean no link, a single uuid is accepted
  for a multiple field and a one-item list for a single one.
  """
  @spec cast_value(map(), term()) :: {:ok, nil | String.t() | [String.t()]} | {:error, String.t()}
  def cast_value(field, value) do
    values =
      value
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))

    cond do
      not Enum.all?(values, &uuid?/1) ->
        {:error, gettext("must link to records by their id")}

      multiple?(field) ->
        {:ok, Enum.uniq(values)}

      match?([_, _ | _], Enum.uniq(values)) ->
        {:error, gettext("can link to one record only")}

      true ->
        {:ok, List.first(values)}
    end
  end

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_), do: false

  # ── Target entities ──────────────────────────────────────────────

  @doc """
  The entity a relation field points at, or `nil` when it no longer
  exists. `target_entity` may hold the entity's uuid or its name.
  """
  @spec target_entity(map()) :: Entities.t() | nil
  def target_entity(field) do
    field |> List.wrap() |> target_entities() |> Map.get(field["target_entity"])
  end

  @doc """
  Resolves the targets of many relation fields in one query:
  `%{target_ref => entity}`. Refs that match nothing are absent.
  """
  @spec target_entities([map()]) :: %{optional(String.t()) => Entities.t()}
  def target_entities(fields) do
    refs =
      fields
      |> Enum.map(& &1["target_entity"])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    {uuid_refs, name_refs} = Enum.split_with(refs, &uuid?/1)

    if refs == [] do
      %{}
    else
      entities =
        from(e in Entities, where: e.uuid in ^uuid_refs or e.name in ^name_refs)
        |> repo().all()

      Enum.reduce(entities, %{}, fn entity, acc ->
        acc
        |> put_if(entity.uuid in uuid_refs, entity.uuid, entity)
        |> put_if(entity.name in name_refs, entity.name, entity)
      end)
    end
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  @doc """
  Which relation fields, on which entities, point at the given entity:
  `[{source_entity, [field, …]}, …]`.
  """
  @spec referencing_fields(Entities.t()) :: [{Entities.t(), [map()]}]
  def referencing_fields(%Entities{} = target) do
    Entities
    |> repo().all()
    |> Enum.map(fn source ->
      {source, Enum.filter(relation_fields(source), &points_at?(&1, target))}
    end)
    |> Enum.reject(fn {_source, fields} -> fields == [] end)
  end

  defp points_at?(field, target), do: field["target_entity"] in [target.uuid, target.name]

  # ── Primary-language data ────────────────────────────────────────

  @doc """
  The map a record's links live in: the primary language's data for a
  multilang record, the data itself otherwise.
  """
  @spec link_data(map() | nil) :: map()
  def link_data(data), do: Multilang.get_primary_data(data)

  @doc """
  Writes `value` under `key` in the map `link_data/1` reads, keeping
  every other language as it is.
  """
  @spec put_link(map() | nil, String.t(), term()) :: map()
  def put_link(data, key, value) do
    data = data || %{}

    if Multilang.multilang_data?(data) do
      entry_key = primary_entry_key(data)
      Map.update(data, entry_key, %{key => value}, &Map.put(&1 || %{}, key, value))
    else
      Map.put(data, key, value)
    end
  end

  # The key the primary language's data is stored under. Usually the
  # `_primary_language` marker itself; hand-written or migrated rows may
  # use the same language under a dialect key instead ("en" vs "en-US"),
  # which `Multilang.get_primary_data/1` also reads.
  defp primary_entry_key(data) do
    primary = data["_primary_language"]

    if is_map(data[primary]) do
      primary
    else
      base = safe_base(primary)

      Enum.find(Map.keys(data), primary, fn key ->
        key != "_primary_language" and is_map(data[key]) and safe_base(key) == base
      end)
    end
  end

  defp safe_base(code) when is_binary(code) and code != "" do
    DialectMapper.extract_base(code)
  rescue
    _ -> code
  end

  defp safe_base(code), do: code

  @doc """
  Brings a record's `data` into shape for its relation fields: each value
  in its canonical form (see `cast_value/2`) in the primary language, and
  no copy under any secondary language. Values that do not cast are left
  as they are for validation to report.
  """
  @spec normalize_data(map() | nil, [map()]) :: map() | nil
  def normalize_data(data, []), do: data
  def normalize_data(nil, _fields), do: nil

  def normalize_data(data, fields) when is_map(data) do
    keys = Enum.map(fields, & &1["key"])

    data =
      if Multilang.multilang_data?(data) do
        primary = primary_entry_key(data)

        Map.new(data, fn
          {lang, %{} = lang_data} when lang != primary -> {lang, Map.drop(lang_data, keys)}
          other -> other
        end)
      else
        data
      end

    link_data = link_data(data)

    Enum.reduce(fields, data, fn field, acc ->
      key = field["key"]

      with true <- Map.has_key?(link_data, key),
           {:ok, value} <- cast_value(field, link_data[key]) do
        put_link(acc, key, value)
      else
        _ -> acc
      end
    end)
  end

  def normalize_data(data, _fields), do: data

  # ── Write-time reference check ───────────────────────────────────

  @doc """
  Checks the links a write adds, against the row as it is NOW.

  A link counts as added when the record's current row (`record_uuid`,
  read `FOR UPDATE`; `nil` for a new record) does not hold it. Each added
  uuid must be a live record of the field's target entity. One exception,
  which is not an error: a uuid the caller's own copy of the record held
  (`stale_data`) whose record no longer exists at all. That is a link a
  permanent delete pruned after the caller loaded the record; saving the
  stale copy must not bring it back, so it is dropped.

  Returns `{:ok, drops}` — `%{field_key => [uuid]}` to remove from the
  new data — or `{:error, [{field, message}]}`.

  Locking: the linked records are read `FOR SHARE` BEFORE the source row
  is read `FOR UPDATE`. A permanent delete takes the same two in the same
  order (target, then sources — see `EntityData.delete/2`), so a save and
  a delete never deadlock, and neither can slip a link past the other.
  The locks last as long as the caller's transaction; `EntityData`
  runs its writes inside one.
  """
  @spec check_references([map()], map() | nil, map() | nil, String.t() | nil) ::
          {:ok, %{optional(String.t()) => [String.t()]}} | {:error, [{map(), String.t()}]}
  def check_references(fields, new_data, stale_data, record_uuid) do
    new_links = link_data(new_data)
    linked = fields |> Enum.flat_map(&uuids(new_links[&1["key"]])) |> Enum.uniq()

    if linked == [] do
      {:ok, %{}}
    else
      found = lock_linked(linked)
      current_links = record_uuid |> current_data() |> link_data()
      stale_links = link_data(stale_data)

      fields
      |> Enum.map(fn field ->
        key = field["key"]
        {field, uuids(new_links[key]) -- uuids(current_links[key]), uuids(stale_links[key])}
      end)
      |> Enum.reject(fn {_field, added, _stale} -> added == [] end)
      |> reference_verdict(found)
    end
  end

  defp reference_verdict([], _found), do: {:ok, %{}}

  defp reference_verdict(added, found) do
    targets = target_entities(Enum.map(added, &elem(&1, 0)))

    {drops, errors} =
      Enum.reduce(added, {%{}, []}, fn {field, uuids, stale}, {drops, errors} ->
        # Held by the caller's copy and gone from the database: pruned.
        gone = Enum.filter(uuids, &(&1 in stale and not Map.has_key?(found, &1)))
        target = Map.get(targets, field["target_entity"])

        errors =
          case uuids -- gone do
            [] -> errors
            rest -> errors ++ field_errors(field, rest, target, found)
          end

        drops = if gone == [], do: drops, else: Map.put(drops, field["key"], gone)
        {drops, errors}
      end)

    if errors == [], do: {:ok, drops}, else: {:error, errors}
  end

  defp lock_linked(uuids) do
    from(d in EntityData,
      where: d.uuid in ^uuids,
      order_by: d.uuid,
      lock: "FOR SHARE",
      select: {d.uuid, {d.entity_uuid, d.status}}
    )
    |> repo().all()
    |> Map.new()
  end

  defp current_data(nil), do: nil

  defp current_data(record_uuid) do
    from(d in EntityData, where: d.uuid == ^record_uuid, lock: "FOR UPDATE", select: d.data)
    |> repo().one()
  end

  @doc """
  Removes `gone` uuids from the link stored under `key`, keeping its
  shape (a list stays a list, a single link becomes `nil`).
  """
  @spec remove_links(map(), String.t(), [String.t()]) :: map()
  def remove_links(data, key, gone) do
    put_link(data, key, drop_uuids(link_data(data)[key], MapSet.new(gone)))
  end

  defp field_errors(field, _uuids, nil, _found),
    do: [{field, gettext("links to an entity that no longer exists")}]

  defp field_errors(field, uuids, target, found) do
    target_uuid = target.uuid

    cond do
      Enum.any?(uuids, &(not match?({^target_uuid, _}, found[&1]))) ->
        [
          {field,
           gettext("can only link to %{entity} records",
             entity: target.display_name_plural || target.display_name
           )}
        ]

      Enum.any?(uuids, &match?({_, @soft_delete_status}, found[&1])) ->
        [{field, gettext("cannot link to a record in the trash")}]

      true ->
        []
    end
  end

  # ── Reading ──────────────────────────────────────────────────────

  @doc """
  The records a relation field links to, loaded in one query per target
  entity however many source records there are.

  Given a list of records it returns `%{record_uuid => [linked_record]}`
  (every record gets a key, `[]` when it links to nothing); given one
  record, the list. Linked records come in the target entity's own order
  (its sort mode: manual position, or newest first). Links to missing or
  trashed records are skipped.

  `key` must name a relation field of each record's entity. Records may
  belong to different entities as long as each has that field; `:entity`
  is used when preloaded and loaded in one query otherwise.

  ## Options

    * `:statuses` — only return linked records in these statuses (e.g.
      `["published"]` for a public page). Default: every status but trashed.
    * `:lang` — resolve the linked records' title and data for a language,
      as `EntityData.get/2` does.
    * `:preload` — associations to preload on the linked records
      (default `[]`).
  """
  @spec resolve([EntityData.t()] | EntityData.t(), String.t(), keyword()) ::
          %{optional(String.t()) => [EntityData.t()]} | [EntityData.t()]
  def resolve(records, key, opts \\ [])

  def resolve(%EntityData{} = record, key, opts) do
    [record] |> resolve(key, opts) |> Map.get(record.uuid, [])
  end

  def resolve(records, key, opts) when is_list(records) and is_binary(key) do
    entities = source_entities(records)

    fields_by_record =
      Map.new(records, fn record ->
        entity = Map.fetch!(entities, record.entity_uuid)

        field =
          Enum.find(relation_fields(entity), &(&1["key"] == key)) ||
            raise ArgumentError,
                  "#{inspect(key)} is not a relation field of entity #{inspect(entity.name)}"

        {record.uuid, field}
      end)

    targets = target_entities(Map.values(fields_by_record))

    linked_by_target =
      records
      |> Enum.group_by(&Map.get(targets, fields_by_record[&1.uuid]["target_entity"]))
      |> Map.delete(nil)
      |> Map.new(fn {target, group} ->
        uuids = Enum.flat_map(group, &uuids(link_data(&1.data)[key]))
        {target.uuid, load_linked(target, uuids, opts)}
      end)

    Map.new(records, fn record ->
      target = Map.get(targets, fields_by_record[record.uuid]["target_entity"])
      wanted = MapSet.new(uuids(link_data(record.data)[key]))

      linked =
        if target,
          do: Enum.filter(linked_by_target[target.uuid], &MapSet.member?(wanted, &1.uuid)),
          else: []

      {record.uuid, linked}
    end)
  end

  defp source_entities(records) do
    preloaded =
      for %EntityData{entity: %Entities{} = entity} <- records,
          into: %{},
          do: {entity.uuid, entity}

    missing =
      records
      |> Enum.map(& &1.entity_uuid)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(preloaded, &1))

    loaded =
      if missing == [],
        do: %{},
        else:
          from(e in Entities, where: e.uuid in ^missing)
          |> repo().all()
          |> Map.new(&{&1.uuid, &1})

    Map.merge(preloaded, loaded)
  end

  defp load_linked(_target, [], _opts), do: []

  defp load_linked(target, uuids, opts) do
    uuids = Enum.uniq(uuids)

    query =
      from(d in EntityData,
        where: d.entity_uuid == ^target.uuid and d.uuid in ^uuids,
        order_by: ^EntityData.sort_order_for(Entities.get_sort_mode(target)),
        preload: ^Keyword.get(opts, :preload, [])
      )

    query =
      case opts[:statuses] do
        statuses when is_list(statuses) ->
          from(d in query, where: d.status in ^(statuses -- [@soft_delete_status]))

        _ ->
          from(d in query, where: d.status != ^@soft_delete_status)
      end

    query
    |> repo().all()
    |> maybe_resolve_langs(opts[:lang])
  end

  defp maybe_resolve_langs(records, nil), do: records
  defp maybe_resolve_langs(records, lang), do: EntityData.resolve_languages(records, lang)

  @doc """
  Titles for every record the given records' relation fields link to, in
  one query: `%{uuid => %{title:, status:}}`. Trashed targets are included
  (flagged by `status`), missing ones are absent. Used by the admin list
  and readonly views, which show titles rather than uuids.
  """
  @spec labels([EntityData.t()] | [{Entities.t() | map(), map() | nil}], keyword()) ::
          %{optional(String.t()) => %{title: String.t(), status: String.t()}}
  def labels(records, opts \\ []) do
    records
    |> Enum.flat_map(&linked_uuids/1)
    |> Enum.uniq()
    |> labels_for(opts)
  end

  defp linked_uuids(%EntityData{entity: %Entities{} = entity, data: data}),
    do: linked_uuids({entity, data})

  defp linked_uuids({entity, data}) do
    links = link_data(data)
    Enum.flat_map(relation_fields(entity), &uuids(links[&1["key"]]))
  end

  defp linked_uuids(_), do: []

  @doc "Titles and statuses for the given record uuids: `%{uuid => %{title:, status:}}`."
  @spec labels_for([String.t()], keyword()) ::
          %{optional(String.t()) => %{title: String.t(), status: String.t()}}
  def labels_for(uuids, opts \\ [])
  def labels_for([], _opts), do: %{}

  def labels_for(uuids, opts) do
    from(d in EntityData, where: d.uuid in ^Enum.uniq(uuids))
    |> repo().all()
    |> maybe_resolve_langs(opts[:lang])
    |> Map.new(&{&1.uuid, %{title: &1.title || "", status: &1.status}})
  end

  # ── Admin picker ─────────────────────────────────────────────────

  @doc """
  What the admin form needs to draw each relation field of `entity` for a
  record holding `data`: `%{field_key => context}` where a context is

      %{
        mode: :list | :search | :missing,
        target: entity | nil,
        options: [%{uuid:, title:, status:}],   # :list only — every live record
        labels: %{uuid => %{title:, status:}}   # the records currently linked
      }

  A target with at most `list_limit/0` live records is `:list` (every
  record offered, in the target's order); a bigger one is `:search`;
  `:missing` means the target entity no longer exists. One query per
  target plus one for the linked records' titles.
  """
  @spec picker_contexts(Entities.t() | map(), map() | nil, keyword()) :: %{
          optional(String.t()) => map()
        }
  def picker_contexts(entity, data, opts \\ []) do
    case relation_fields(entity) do
      [] ->
        %{}

      fields ->
        targets = target_entities(fields)
        labels = labels([{entity, data}], opts)

        options_by_target =
          targets
          |> Map.values()
          |> Enum.uniq_by(& &1.uuid)
          |> Map.new(&{&1.uuid, list_options(&1, opts)})

        Map.new(fields, fn field ->
          target = Map.get(targets, field["target_entity"])
          {field["key"], context(target, options_by_target, labels)}
        end)
    end
  end

  defp context(nil, _options_by_target, labels),
    do: %{mode: :missing, target: nil, options: [], labels: labels}

  defp context(target, options_by_target, labels) do
    case options_by_target[target.uuid] do
      {:list, options} -> %{mode: :list, target: target, options: options, labels: labels}
      :search -> %{mode: :search, target: target, options: [], labels: labels}
    end
  end

  # One query, one row past the limit: that row existing is what says
  # "too many to list".
  defp list_options(target, opts) do
    rows =
      from(d in EntityData,
        where: d.entity_uuid == ^target.uuid and d.status != ^@soft_delete_status,
        order_by: ^EntityData.sort_order_for(Entities.get_sort_mode(target)),
        limit: ^(@list_limit + 1)
      )
      |> repo().all()
      |> maybe_resolve_langs(opts[:lang])

    if length(rows) > @list_limit do
      :search
    else
      {:list, Enum.map(rows, &%{uuid: &1.uuid, title: &1.title || "", status: &1.status})}
    end
  end

  @doc """
  Searches a relation field's target for the admin search picker. Returns
  `{rows, has_more?}` with rows shaped for core's `SearchPicker`
  (`%{kind:, uuid:, label:, sublabel:, icon:}`). Trashed records and the
  uuids in `exclude` are left out; an empty query lists the first page.
  """
  @spec search(map(), String.t(), pos_integer(), [String.t()], keyword()) ::
          {[map()], boolean()}
  def search(field, query, limit, exclude \\ [], opts \\ []) do
    case target_entity(field) do
      nil ->
        {[], false}

      target ->
        limit = limit |> max(1) |> min(100)
        pattern = "%" <> escape_like(String.trim(query || "")) <> "%"

        rows =
          from(d in EntityData,
            where:
              d.entity_uuid == ^target.uuid and d.status != ^@soft_delete_status and
                ilike(d.title, ^pattern) and d.uuid not in ^uuids(exclude),
            order_by: ^EntityData.sort_order_for(Entities.get_sort_mode(target)),
            limit: ^(limit + 1)
          )
          |> repo().all()
          |> maybe_resolve_langs(opts[:lang])

        {rows |> Enum.take(limit) |> Enum.map(&search_row/1), length(rows) > limit}
    end
  end

  defp search_row(record) do
    %{
      kind: "record",
      uuid: record.uuid,
      label: record.title || "",
      sublabel: if(record.status == "published", do: "", else: status_label(record.status)),
      icon: "hero-link"
    }
  end

  @doc "Translated label for a record status, as the picker shows it."
  @spec status_label(String.t()) :: String.t()
  def status_label("draft"), do: gettext("Draft")
  def status_label("archived"), do: gettext("Archived")
  def status_label("trashed"), do: gettext("In trash")
  def status_label("published"), do: gettext("Published")
  def status_label(other), do: to_string(other)

  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # ── Deleting targets ─────────────────────────────────────────────

  @doc """
  How many live records link to `record` through a relation field.
  """
  @spec count_referencing(EntityData.t()) :: non_neg_integer()
  def count_referencing(%EntityData{} = record) do
    record |> List.wrap() |> count_referencing_many() |> Map.get(record.uuid, 0)
  end

  @doc """
  For each record, how many live records link to it:
  `%{uuid => count}` (records nobody links to are absent). One query per
  entity that has a relation field pointing at one of their entities.
  """
  @spec count_referencing_many([EntityData.t()]) :: %{optional(String.t()) => pos_integer()}
  def count_referencing_many([]), do: %{}

  def count_referencing_many(records) do
    uuids = Enum.map(records, & &1.uuid)
    wanted = MapSet.new(uuids)

    records
    |> sources_for()
    |> Enum.flat_map(fn {source, fields} ->
      source
      |> candidate_rows(uuids)
      |> Enum.flat_map(fn row ->
        links = link_data(row.data)

        fields
        |> Enum.flat_map(&uuids(links[&1["key"]]))
        |> Enum.uniq()
        |> Enum.filter(&MapSet.member?(wanted, &1))
      end)
    end)
    |> Enum.frequencies()
  end

  @doc """
  Removes the given records' uuids from every record that links to them.
  Takes `[{uuid, entity_uuid}]` of the records about to be deleted and
  returns the rewritten records as `[{uuid, entity_uuid}]`.

  Runs inside the delete's transaction, AFTER the targets are locked and
  BEFORE they are deleted (`EntityData.delete/2`, `bulk_delete/2`): the
  same lock order as a save (`check_references/4`), so the two never
  deadlock and a save cannot add a link the prune has already passed.

  Each rewrite is one atomic `UPDATE` that edits the relation value in
  the row's CURRENT `data` (`jsonb_set` over the stored array or string),
  never a snapshot of the whole map: an edit to any other key that lands
  between reading the candidates and writing survives, and two prunes of
  the same row compose.

  It broadcasts nothing: the caller calls `after_prune/1` once the
  transaction has committed.
  """
  @spec prune_deleted([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def prune_deleted([]), do: []

  def prune_deleted(deleted) do
    uuids = deleted |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    gone = MapSet.new(uuids)
    entity_uuids = deleted |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    targets = from(e in Entities, where: e.uuid in ^entity_uuids) |> repo().all()

    targets
    |> Enum.flat_map(&referencing_fields/1)
    |> merge_sources()
    |> Enum.flat_map(fn {source, fields} -> prune_source(source, fields, uuids, gone) end)
  end

  @doc """
  After a prune commits: broadcasts `:data_updated` for every rewritten
  record, and re-exports each rewritten record's entity when its data is
  mirrored — the file would otherwise keep the dead slug reference.
  """
  @spec after_prune([{String.t(), String.t()}]) :: :ok
  def after_prune(rewritten) do
    Enum.each(rewritten, fn {uuid, entity_uuid} ->
      Events.broadcast_data_updated(entity_uuid, uuid)
    end)

    rewritten
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> Enum.each(&mirror_entity/1)
  end

  defp mirror_entity(entity_uuid) do
    with %Entities{} = entity <- Entities.get_entity(entity_uuid),
         true <- Entities.mirror_data_enabled?(entity) do
      Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, fn ->
        Exporter.export_entity(entity)
      end)
    end

    :ok
  end

  defp prune_source(source, fields, uuids, gone) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    source
    |> candidate_rows(uuids, include_trashed: true)
    |> Enum.flat_map(fn row ->
      # Where the value lives (primary language or flat) and which fields
      # mention a deleted record come from the candidate read; the value
      # itself is edited in SQL against the row as it is when written.
      prefix = if Multilang.multilang_data?(row.data), do: [primary_entry_key(row.data)], else: []
      links = link_data(row.data)

      rewritten =
        fields
        |> Enum.filter(fn field ->
          Enum.any?(uuids(links[field["key"]]), &MapSet.member?(gone, &1))
        end)
        |> Enum.map(&prune_value(row.uuid, prefix ++ [&1["key"]], uuids, now))
        |> Enum.sum()

      if rewritten > 0, do: [{row.uuid, row.entity_uuid}], else: []
    end)
  end

  # Drops `uuids` from the relation value at `path`: from a list, keeping
  # the rest in order; a single link becomes JSON null. Only touches the
  # row when the value still mentions one of them.
  defp prune_value(record_uuid, path, uuids, now) do
    pattern = Enum.join(uuids, "|")

    {count, _} =
      from(d in EntityData,
        where:
          d.uuid == ^record_uuid and
            fragment("(? #> ?::text[])::text ~ ?", d.data, ^path, ^pattern),
        update: [
          set: [
            data:
              fragment(
                """
                jsonb_set(?, ?::text[], CASE jsonb_typeof(? #> ?::text[])
                  WHEN 'array' THEN COALESCE(
                    (SELECT jsonb_agg(e ORDER BY i)
                       FROM jsonb_array_elements(? #> ?::text[]) WITH ORDINALITY AS t(e, i)
                      WHERE NOT ((e #>> '{}') = ANY(?::text[]))),
                    '[]'::jsonb)
                  WHEN 'string' THEN
                    CASE WHEN (? #>> ?::text[]) = ANY(?::text[]) THEN 'null'::jsonb
                         ELSE ? #> ?::text[] END
                  ELSE ? #> ?::text[]
                END)
                """,
                d.data,
                ^path,
                d.data,
                ^path,
                d.data,
                ^path,
                ^uuids,
                d.data,
                ^path,
                ^uuids,
                d.data,
                ^path,
                d.data,
                ^path
              ),
            date_updated: ^now
          ]
        ]
      )
      |> repo().update_all([])

    count
  end

  defp drop_uuids(value, gone) when is_list(value),
    do: Enum.reject(value, &MapSet.member?(gone, &1))

  defp drop_uuids(value, gone), do: if(MapSet.member?(gone, value), do: nil, else: value)

  defp sources_for(records) do
    entity_uuids = records |> Enum.map(& &1.entity_uuid) |> Enum.uniq()

    from(e in Entities, where: e.uuid in ^entity_uuids)
    |> repo().all()
    |> Enum.flat_map(&referencing_fields/1)
    |> merge_sources()
  end

  # Two targets can share a source entity; query it once.
  defp merge_sources(pairs) do
    pairs
    |> Enum.group_by(fn {source, _} -> source.uuid end)
    |> Enum.map(fn {_uuid, [{source, _} | _] = group} ->
      {source, group |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq_by(& &1["key"])}
    end)
  end

  # Rows of `source` whose data mentions any of the uuids. A textual
  # pre-filter (uuids are plain hex and dashes, safe in a regex); the
  # caller then reads the relation fields themselves.
  defp candidate_rows(source, uuids, opts \\ []) do
    pattern = Enum.join(uuids, "|")

    query =
      from(d in EntityData,
        where: d.entity_uuid == ^source.uuid and fragment("?::text ~ ?", d.data, ^pattern),
        order_by: d.uuid,
        select: struct(d, [:uuid, :entity_uuid, :data, :status])
      )

    query =
      if opts[:include_trashed],
        do: query,
        else: from(d in query, where: d.status != ^@soft_delete_status)

    repo().all(query)
  end

  # ── Mirror export / import ───────────────────────────────────────

  @doc """
  Rewrites a definition's relation fields for export: `target_entity`
  becomes the target's name, which means the same thing in another
  install (uuids do not).
  """
  @spec export_fields([map()] | nil) :: [map()] | nil
  def export_fields(nil), do: nil

  def export_fields(fields) when is_list(fields) do
    targets = fields |> relation_fields() |> target_entities()

    Enum.map(fields, fn field ->
      case relation?(field) && Map.get(targets, field["target_entity"]) do
        %Entities{name: name} -> Map.put(field, "target_entity", name)
        _ -> field
      end
    end)
  end

  @doc """
  Rewrites imported relation fields' `target_entity` from a name to the
  local entity's uuid when that entity exists. A target not imported yet
  keeps its name, which `target_entity/1` resolves as well.
  """
  @spec import_fields([map()] | nil) :: [map()] | nil
  def import_fields(nil), do: nil

  def import_fields(fields) when is_list(fields) do
    targets = fields |> relation_fields() |> target_entities()

    Enum.map(fields, fn field ->
      case relation?(field) && Map.get(targets, field["target_entity"]) do
        %Entities{uuid: uuid} -> Map.put(field, "target_entity", uuid)
        _ -> field
      end
    end)
  end

  @doc """
  Rewrites records' relation values for export: each linked uuid becomes
  `%{"slug" => slug}` (a record's slug is what the importer matches on),
  or stays a uuid when the target has no slug. Links to missing records
  are dropped. Takes the entity and its records' `data` maps, returns
  the rewritten maps in the same order.
  """
  @spec export_data(Entities.t(), [map() | nil]) :: [map() | nil]
  def export_data(entity, datas) do
    case relation_fields(entity) do
      [] ->
        datas

      fields ->
        uuids = Enum.flat_map(datas, &linked_uuids({entity, &1})) |> Enum.uniq()

        slugs =
          if uuids == [],
            do: %{},
            else:
              from(d in EntityData, where: d.uuid in ^uuids, select: {d.uuid, d.slug})
              |> repo().all()
              |> Map.new()

        Enum.map(datas, &export_links(&1, fields, slugs))
    end
  end

  defp export_links(nil, _fields, _slugs), do: nil

  defp export_links(data, fields, slugs) do
    links = link_data(data)

    fields
    |> Enum.filter(&Map.has_key?(links, &1["key"]))
    |> Enum.reduce(data, fn field, acc ->
      refs =
        links[field["key"]]
        |> uuids()
        |> Enum.filter(&Map.has_key?(slugs, &1))
        |> Enum.map(&export_ref(&1, slugs[&1]))

      put_link(acc, field["key"], if(multiple?(field), do: refs, else: List.first(refs)))
    end)
  end

  defp export_ref(_uuid, slug) when is_binary(slug) and slug != "", do: %{"slug" => slug}
  defp export_ref(uuid, _slug), do: uuid

  @doc """
  Turns imported relation values back into local uuids: a
  `%{"slug" => slug}` ref becomes the uuid of the target's record with
  that slug, a uuid ref is kept when that record exists in the target.

  `planned` — `%{{target_entity_name, slug} => uuid}` — names records the
  same import run is about to write (`Mirror.Importer` assigns their
  uuids up front), so a link can point at a record that does not exist
  yet; it is checked once the whole run is written. It wins over the
  database.

  Returns `{data, unresolved}`: `unresolved` is `%{field_key => [ref]}`
  for refs that matched nothing, which are left out of `data`.
  """
  @spec import_data(Entities.t(), map() | nil, map()) :: {map() | nil, map()}
  def import_data(entity, data, planned \\ %{})
  def import_data(_entity, nil, _planned), do: {nil, %{}}

  def import_data(entity, data, planned) when is_map(data) do
    fields = relation_fields(entity)
    links = link_data(data)
    targets = target_entities(fields)

    fields
    |> Enum.filter(&Map.has_key?(links, &1["key"]))
    |> Enum.reduce({data, %{}}, fn field, {acc, unresolved} ->
      refs = List.wrap(links[field["key"]])
      target = Map.get(targets, field["target_entity"])
      {resolved, missing} = resolve_import_refs(refs, target, planned)
      value = if multiple?(field), do: resolved, else: List.first(resolved)

      unresolved =
        if missing == [], do: unresolved, else: Map.put(unresolved, field["key"], missing)

      {put_link(acc, field["key"], value), unresolved}
    end)
  end

  def import_data(_entity, data, _planned), do: {data, %{}}

  defp resolve_import_refs(refs, nil, _planned), do: {[], refs}

  defp resolve_import_refs(refs, target, planned) do
    slugs = for %{"slug" => slug} <- refs, is_binary(slug), do: slug
    uuids = Enum.filter(refs, &uuid?/1)

    found =
      from(d in EntityData,
        where: d.entity_uuid == ^target.uuid and (d.slug in ^slugs or d.uuid in ^uuids),
        select: {d.uuid, d.slug}
      )
      |> repo().all()

    by_slug = Map.new(found, fn {uuid, slug} -> {slug, uuid} end)

    planned_here =
      for {{name, slug}, uuid} <- planned, name == target.name, into: %{}, do: {slug, uuid}

    known = MapSet.new(Enum.map(found, &elem(&1, 0)) ++ Map.values(planned_here))

    {resolved, missing} =
      Enum.reduce(refs, {[], []}, fn ref, {resolved, missing} ->
        case import_ref(ref, planned_here, by_slug, known) do
          nil -> {resolved, [ref | missing]}
          uuid -> {[uuid | resolved], missing}
        end
      end)

    {resolved |> Enum.reverse() |> Enum.uniq(), Enum.reverse(missing)}
  end

  defp import_ref(%{"slug" => slug}, planned_here, by_slug, _known),
    do: planned_here[slug] || by_slug[slug]

  defp import_ref(uuid, _planned_here, _by_slug, known) when is_binary(uuid),
    do: if(MapSet.member?(known, uuid), do: uuid)

  defp import_ref(_ref, _planned_here, _by_slug, _known), do: nil

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
