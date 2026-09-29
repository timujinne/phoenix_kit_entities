defmodule PhoenixKitEntities.Mirror.Importer do
  @moduledoc """
  Handles import of entities and entity data from JSON files with conflict resolution.

  Each JSON file contains both the entity definition and all its data records.

  ## File Format

      {
        "export_version": "1.0",
        "exported_at": "2025-12-11T10:30:00Z",
        "definition": { ... entity schema ... },
        "data": [ ... array of data records ... ]
      }

  ## Conflict Strategies

  - `:skip` - Skip import if record already exists (default)
  - `:overwrite` - Replace existing record with imported data
  - `:merge` - Merge imported data with existing record (keeps existing values where new is nil)

  ## Conflict Detection

  - Entity definitions: matched by `name` field
  - Entity data records: matched by `entity_name` + `slug`

  ## Relation fields

  The exporter writes a relation's target as the entity's name and each
  link as `{"slug": …}`; both come back as local uuids here.

  One call (`import_entity/2`, `import_from_data/2`, `import_all/1`,
  `import_selected/1`) is one run, written as a graph in ONE transaction:

    1. every definition in the run is imported, then relation fields are
       pointed at the local uuids of their targets;
    2. every record gets its uuid up front — an existing record (matched
       by slug) keeps its own, a new one is assigned one — so a link can
       name a record that is written later in the run, in any file and in
       any order, cycles included;
    3. every record is validated before anything is written. A record that
       fails is reported and not written, and so is any record that links
       to one (repeated until nothing else drops out), so what is written
       never points at a record that is not there;
    4. the rest is written, each link checked once all exist; broadcasts
       and mirror exports follow the commit.

  A ref that matches nothing — not in the database, not in the run — is
  left out and listed under `:unresolved_links` in the result (a
  required relation left empty that way fails validation). If a write
  fails anyway (a race with another writer), the whole run rolls back and
  every result says so.
  """

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Slug
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Events
  alias PhoenixKitEntities.Mirror.Exporter
  alias PhoenixKitEntities.Mirror.Storage
  alias PhoenixKitEntities.Relations

  @type conflict_strategy :: :skip | :overwrite | :merge
  @type import_result ::
          {:ok, :created, any()}
          | {:ok, :updated, any()}
          | {:ok, :skipped, any()}
          | {:error, term()}

  # ============================================================================
  # Import Operations
  # ============================================================================

  @doc """
  Imports an entity (definition + data) from a JSON file.

  ## Parameters
    - `entity_name` - The entity name (file name without .json)
    - `strategy` - Conflict resolution strategy (default: :skip)

  ## Returns
    - `{:ok, %{definition: result, data: [results]}}` on success
    - `{:error, reason}` on failure
  """
  @spec import_entity(String.t(), conflict_strategy()) :: {:ok, map()} | {:error, term()}
  def import_entity(entity_name, strategy \\ :skip) do
    with {:ok, json_data} <- read_entity_file(entity_name) do
      import_from_data(json_data, strategy)
    end
  end

  defp read_entity_file(entity_name) do
    case Storage.read_entity(entity_name) do
      {:ok, json_data} -> {:ok, json_data}
      {:error, :not_found} -> {:error, {:file_not_found, entity_name}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Imports from parsed JSON data (definition + data).

  Returns `{:ok, %{definition: result, data: [result], unresolved_links: [...]}}`.
  """
  @spec import_from_data(map(), conflict_strategy()) :: {:ok, map()} | {:error, term()}
  def import_from_data(%{"definition" => definition, "data" => data}, strategy)
      when is_map(definition) and is_list(data) do
    {[result], unresolved} =
      run([unit(definition, data, strategy, fn _record, _i -> strategy end)])

    {:ok, Map.put(result, :unresolved_links, unresolved)}
  end

  def import_from_data(_, _), do: {:error, :invalid_format}

  # ============================================================================
  # One run: a graph written in one transaction (see the moduledoc)
  # ============================================================================

  # A unit is one entity file's work: what to do with its definition
  # (`:leave` = not selected, untouched) and, per record, an action or
  # `:leave`.
  defp unit(definition, data, def_action, record_action) do
    %{
      name: definition["name"],
      definition: definition,
      data: data,
      def_action: def_action,
      record_action: record_action
    }
  end

  defp run(units) do
    txn =
      repo().transaction(fn ->
        units
        |> Enum.map(&import_unit_definition/1)
        |> Enum.map(&load_unit_entity/1)
        |> plan_records()
        |> resolve_links()
        |> drop_broken()
        |> write_records()
        |> verify_links()
      end)

    case txn do
      {:ok, units} ->
        announce(units)
        {Enum.map(units, &unit_result/1), unresolved_links(units)}

      {:error, {:aborted, reason, units}} ->
        {Enum.map(units, &aborted_result(&1, reason)), []}

      # A write failed mid-run (`write_record/2`): nothing was committed.
      {:error, {:write_failed, _} = reason} ->
        {Enum.map(units, &rolled_back_unit(&1, reason)), []}
    end
  end

  defp rolled_back_unit(unit, reason) do
    %{
      definition: {:error, {:rolled_back, reason}},
      data: Enum.map(unit.data, fn _ -> {:error, {:rolled_back, reason}} end)
    }
  end

  defp import_unit_definition(%{def_action: :leave} = unit),
    do: Map.put(unit, :def_result, {:ok, :skipped, nil})

  defp import_unit_definition(unit),
    do: Map.put(unit, :def_result, import_definition(unit.definition, unit.def_action))

  # After every definition of the run exists, relation fields can point at
  # their targets' uuids (a target imported after its source still had
  # only a name when the source was written).
  defp load_unit_entity(unit) do
    entity =
      case Entities.get_entity_by_name(unit.name) do
        nil -> nil
        entity -> relink_definition(entity)
      end

    Map.put(unit, :entity, entity)
  end

  defp relink_definition(entity) do
    fields = Relations.import_fields(entity.fields_definition)

    with true <- fields != entity.fields_definition,
         {:ok, updated} <- Entities.update_entity(entity, %{fields_definition: fields}) do
      updated
    else
      _ -> entity
    end
  end

  # Each record's operation, with its uuid decided now.
  defp plan_records(units) do
    Enum.map(units, fn unit ->
      records =
        unit.data
        |> Enum.with_index()
        |> Enum.map(fn {json, index} -> plan_record(unit, json, index) end)

      Map.put(unit, :records, records)
    end)
  end

  defp plan_record(%{entity: nil} = unit, json, _index),
    do: %{json: json, op: {:error, {:entity_not_found, unit.name, json["slug"]}}}

  defp plan_record(unit, json, index) do
    slug = json["slug"]

    op =
      case unit.record_action.(json, index) do
        :leave -> :leave
        action -> plan_op(unit.entity, slug, action)
      end

    %{json: json, op: op}
  end

  defp plan_op(entity, slug, action) do
    case if(slug in [nil, ""], do: nil, else: EntityData.get_by_slug(entity.uuid, slug)) do
      nil -> {:create, UUIDv7.generate()}
      existing when action == :skip -> {:skip, existing}
      existing -> {:update, existing, action}
    end
  end

  # `%{{entity_name, slug} => uuid}` for every record the run will write
  # or keeps — what a slug ref resolves to.
  defp planned_uuids(units) do
    for unit <- units,
        record <- unit.records,
        slug <- [record.json["slug"]],
        slug not in [nil, ""],
        uuid <- [op_uuid(record.op)],
        uuid != nil,
        into: %{},
        do: {{unit.name, slug}, uuid}
  end

  defp op_uuid({:create, uuid}), do: uuid
  defp op_uuid({:skip, existing}), do: existing.uuid
  defp op_uuid({:update, existing, _action}), do: existing.uuid
  defp op_uuid(_op), do: nil

  defp resolve_links(units) do
    planned = planned_uuids(units)

    Enum.map(units, fn unit ->
      %{unit | records: Enum.map(unit.records, &resolve_record_links(unit.entity, &1, planned))}
    end)
  end

  defp resolve_record_links(entity, record, planned) do
    if writes?(record) do
      {data, unresolved} = Relations.import_data(entity, record.json["data"], planned)

      record
      |> Map.put(:json, Map.put(record.json, "data", data))
      |> Map.put(:unresolved, unresolved)
    else
      Map.put(record, :unresolved, %{})
    end
  end

  defp writes?(%{op: {:create, _}}), do: true
  defp writes?(%{op: {:update, _, _}}), do: true
  defp writes?(_record), do: false

  # Validate every write before any happens (a failed write inside the
  # run's transaction would abort all of it), then drop the records that
  # link to a record that will not exist.
  defp drop_broken(units) do
    units =
      Enum.map(units, fn unit ->
        %{unit | records: Enum.map(unit.records, &prevalidate(unit.entity, &1))}
      end)

    drop_links_to_missing(units)
  end

  defp prevalidate(entity, %{op: {:create, uuid}} = record) do
    changeset =
      EntityData.changeset(%EntityData{uuid: uuid}, create_attrs(entity, record.json),
        relation_check: :defer
      )

    if changeset.valid?, do: record, else: fail(record, {:validation_failed, changeset})
  end

  defp prevalidate(_entity, %{op: {:update, existing, action}} = record) do
    changeset =
      EntityData.changeset(existing, update_attrs(existing, record.json, action),
        relation_check: :defer
      )

    if changeset.valid?, do: record, else: fail(record, {:validation_failed, changeset})
  end

  defp prevalidate(_entity, record), do: record

  # A failed NEW record keeps its planned uuid, so links to it are found.
  defp fail(%{op: {:create, uuid}} = record, reason),
    do: record |> Map.put(:planned_uuid, uuid) |> Map.put(:op, {:error, reason})

  defp fail(record, reason), do: %{record | op: {:error, reason}}

  # A new record that will not be written leaves every link to it
  # dangling; the records holding one are not written either. Repeat until
  # nothing more drops out (a chain of links drops together).
  defp drop_links_to_missing(units) do
    missing =
      for unit <- units,
          record <- unit.records,
          match?({:error, _}, record.op),
          uuid <- [record[:planned_uuid]],
          uuid != nil,
          into: MapSet.new(),
          do: uuid

    {units, dropped?} =
      Enum.map_reduce(units, false, fn unit, dropped? ->
        {records, now?} =
          Enum.map_reduce(unit.records, false, &drop_if_dangling(unit.entity, &1, &2, missing))

        {%{unit | records: records}, dropped? or now?}
      end)

    if dropped?, do: drop_links_to_missing(units), else: units
  end

  defp drop_if_dangling(entity, record, dropped?, missing) do
    dangling = links_into(entity, record, missing)

    if writes?(record) and dangling != [],
      do: {fail(record, {:broken_links, dangling}), true},
      else: {record, dropped?}
  end

  defp links_into(entity, record, missing) do
    links = Relations.link_data(record.json["data"])

    entity
    |> Relations.relation_fields()
    |> Enum.flat_map(&Relations.uuids(links[&1["key"]]))
    |> Enum.filter(&MapSet.member?(missing, &1))
  end

  defp write_records(units) do
    Enum.map(units, fn unit ->
      %{unit | records: Enum.map(unit.records, &write_record(unit.entity, &1))}
    end)
  end

  @write_opts [relation_check: :defer, defer_notify: true]

  defp write_record(entity, %{op: {:create, uuid}} = record) do
    case EntityData.create(create_attrs(entity, record.json), [uuid: uuid] ++ @write_opts) do
      {:ok, created} -> Map.put(record, :result, {:ok, :created, created})
      {:error, reason} -> repo().rollback({:write_failed, reason})
    end
  end

  defp write_record(_entity, %{op: {:update, existing, action}} = record) do
    case EntityData.update(existing, update_attrs(existing, record.json, action), @write_opts) do
      {:ok, updated} ->
        Map.put(record, :result, {:ok, :updated, updated})

      # A managed record's locked slug is refused before any write, so it
      # does not abort the run.
      {:error, reason} when is_atom(reason) ->
        Map.put(record, :result, {:error, {:refused, reason}})

      {:error, reason} ->
        repo().rollback({:write_failed, reason})
    end
  end

  defp write_record(_entity, %{op: {:skip, existing}} = record),
    do: Map.put(record, :result, {:ok, :skipped, existing})

  defp write_record(_entity, %{op: :leave} = record),
    do: Map.put(record, :result, {:ok, :skipped, nil})

  defp write_record(_entity, %{op: {:error, reason}} = record),
    do: Map.put(record, :result, {:error, reason})

  # Every record is in; now each written link must be a live record of its
  # target. It is by construction — this is the safety net.
  defp verify_links(units) do
    broken =
      for unit <- units,
          %{result: {:ok, status, written}} <- unit.records,
          status in [:created, :updated],
          fields <- [Relations.relation_fields(unit.entity)],
          fields != [],
          {:error, errors} <- [Relations.check_references(fields, written.data, nil, nil)],
          do: {unit.name, written.slug, Enum.map(errors, &elem(&1, 1))}

    if broken == [], do: units, else: repo().rollback({:aborted, {:broken_links, broken}, units})
  end

  defp announce(units) do
    written =
      for unit <- units,
          %{result: {:ok, status, record}} <- unit.records,
          status in [:created, :updated],
          do: {status, record}

    Enum.each(written, fn
      {:created, record} -> Events.broadcast_data_created(record.entity_uuid, record.uuid)
      {:updated, record} -> Events.broadcast_data_updated(record.entity_uuid, record.uuid)
    end)

    written
    |> Enum.map(fn {_status, record} -> record.entity_uuid end)
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
  end

  defp unit_result(unit),
    do: %{definition: unit.def_result, data: Enum.map(unit.records, & &1.result)}

  # The run rolled back: nothing it wrote exists.
  defp aborted_result(unit, reason) do
    undo = fn
      {:ok, status, _} when status in [:created, :updated] -> {:error, {:rolled_back, reason}}
      other -> other
    end

    %{
      definition: undo.(unit.def_result),
      data: Enum.map(unit.records, &undo.(Map.get(&1, :result, {:error, {:rolled_back, reason}})))
    }
  end

  defp unresolved_links(units) do
    for unit <- units,
        %{result: {:ok, status, record}, unresolved: unresolved} <- unit.records,
        status in [:created, :updated],
        {key, refs} <- unresolved,
        do: %{entity: unit.name, slug: record.slug, field: key, refs: refs}
  end

  # ============================================================================
  # Definition Import
  # ============================================================================

  defp import_definition(definition, strategy) do
    entity_name = definition["name"]
    # Relation targets arrive as entity names; point at local uuids where
    # the target already exists (`link_relations/1` catches the rest).
    definition = Map.update(definition, "fields_definition", nil, &Relations.import_fields/1)

    case Entities.get_entity_by_name(entity_name) do
      nil ->
        create_entity_from_import(definition)

      existing_entity ->
        handle_entity_conflict(existing_entity, definition, strategy)
    end
  end

  defp create_entity_from_import(definition) do
    attrs = %{
      name: definition["name"],
      display_name: definition["display_name"],
      display_name_plural: definition["display_name_plural"],
      description: definition["description"],
      icon: definition["icon"],
      status: definition["status"] || "published",
      fields_definition: definition["fields_definition"] || [],
      settings: definition["settings"] || %{},
      created_by_uuid: get_default_user_uuid()
    }

    case Entities.create_entity(attrs) do
      {:ok, entity} -> {:ok, :created, entity}
      # Managed refusals are atoms, not changesets — a definition whose
      # settings claim "managed_by" belongs to the owning module's own
      # provisioning path. Keep the atom labelled as what it is instead
      # of wrapping it as a "changeset".
      {:error, %Ecto.Changeset{} = changeset} -> {:error, {:validation_failed, changeset}}
      {:error, reason} -> {:error, {:refused, reason}}
    end
  end

  defp handle_entity_conflict(existing_entity, _definition, :skip) do
    {:ok, :skipped, existing_entity}
  end

  defp handle_entity_conflict(existing_entity, definition, :overwrite) do
    attrs = %{
      display_name: definition["display_name"],
      display_name_plural: definition["display_name_plural"],
      description: definition["description"],
      icon: definition["icon"],
      status: definition["status"] || existing_entity.status,
      fields_definition: definition["fields_definition"] || [],
      settings: definition["settings"] || %{}
    }

    case Entities.update_entity(existing_entity, attrs) do
      {:ok, entity} -> {:ok, :updated, entity}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, {:validation_failed, changeset}}
      {:error, reason} -> {:error, {:refused, reason}}
    end
  end

  defp handle_entity_conflict(existing_entity, definition, :merge) do
    attrs = build_merged_entity_attrs(existing_entity, definition)

    case Entities.update_entity(existing_entity, attrs) do
      {:ok, entity} -> {:ok, :updated, entity}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, {:validation_failed, changeset}}
      {:error, reason} -> {:error, {:refused, reason}}
    end
  end

  defp build_merged_entity_attrs(existing, definition) do
    %{
      display_name: definition["display_name"] || existing.display_name,
      display_name_plural: definition["display_name_plural"] || existing.display_name_plural,
      description: definition["description"] || existing.description,
      icon: definition["icon"] || existing.icon,
      status: definition["status"] || existing.status,
      fields_definition:
        merge_fields_definition(existing.fields_definition, definition["fields_definition"]),
      settings: deep_merge(existing.settings || %{}, definition["settings"] || %{})
    }
  end

  # ============================================================================
  # Data Import
  # ============================================================================

  defp create_attrs(entity, record_data) do
    %{
      entity_uuid: entity.uuid,
      title: record_data["title"],
      # Generate slug from title if not provided
      slug: generate_slug_if_missing(entity.uuid, record_data["slug"], record_data["title"]),
      status: record_data["status"] || "published",
      data: record_data["data"] || %{},
      metadata: record_data["metadata"] || %{},
      created_by_uuid: get_default_user_uuid()
    }
  end

  defp update_attrs(existing, record_data, :overwrite) do
    %{
      title: record_data["title"],
      slug: record_data["slug"],
      status: record_data["status"] || existing.status,
      data: record_data["data"] || %{},
      metadata: record_data["metadata"] || %{}
    }
  end

  defp update_attrs(existing, record_data, :merge),
    do: build_merged_data_attrs(existing, record_data)

  defp generate_slug_if_missing(_entity_uuid, slug, _title) when is_binary(slug) and slug != "",
    do: slug

  defp generate_slug_if_missing(entity_uuid, _slug, title)
       when is_binary(title) and title != "" do
    base_slug = Slug.slugify(title, transliterate: true)

    if base_slug == "" do
      # Title couldn't be slugified, generate a random one
      "record-#{:rand.uniform(9999)}"
    else
      Slug.ensure_unique(base_slug, &slug_exists?(entity_uuid, &1))
    end
  end

  defp generate_slug_if_missing(_entity_uuid, _slug, _title) do
    # No slug and no title, generate a random slug
    "record-#{:rand.uniform(9999)}"
  end

  defp slug_exists?(entity_uuid, slug) do
    EntityData.get_by_slug(entity_uuid, slug) != nil
  end

  # Preview what slug would be generated (without uniqueness check)
  defp preview_generated_slug(title) when is_binary(title) and title != "" do
    base_slug = Slug.slugify(title, transliterate: true)
    if base_slug == "", do: "(auto-generated)", else: base_slug
  end

  defp preview_generated_slug(_), do: "(auto-generated)"

  # Find the next available slug for preview, considering DB and batch
  defp find_next_available_slug_preview(base_slug, _entity_uuid, _batch_counts)
       when base_slug in ["(auto-generated)", ""] do
    # Can't predict for auto-generated slugs
    "(auto-generated)"
  end

  defp find_next_available_slug_preview(base_slug, entity_uuid, batch_counts) do
    batch_count = Map.get(batch_counts, base_slug, 0)

    # Start checking from base_slug, then -2, -3, etc.
    # But account for how many we've already "claimed" in this batch
    find_available_slug_candidate(base_slug, entity_uuid, batch_count, 1)
  end

  defp find_available_slug_candidate(base_slug, entity_uuid, batch_offset, counter) do
    candidate = if counter == 1, do: base_slug, else: "#{base_slug}-#{counter}"

    # Check if this candidate exists in DB
    db_exists = entity_uuid && slug_exists?(entity_uuid, candidate)

    cond do
      db_exists ->
        # Slug exists in DB, try next number
        find_available_slug_candidate(base_slug, entity_uuid, batch_offset, counter + 1)

      batch_offset > 0 ->
        # This slot is taken by a previous record in this batch
        find_available_slug_candidate(base_slug, entity_uuid, batch_offset - 1, counter + 1)

      true ->
        # Found an available slot
        candidate
    end
  end

  defp build_merged_data_attrs(existing, record_data) do
    %{
      title: record_data["title"] || existing.title,
      slug: record_data["slug"] || existing.slug,
      status: record_data["status"] || existing.status,
      data: deep_merge(existing.data || %{}, record_data["data"] || %{}),
      metadata: deep_merge(existing.metadata || %{}, record_data["metadata"] || %{})
    }
  end

  # ============================================================================
  # Bulk Import
  # ============================================================================

  @doc """
  Imports all entities from the mirror directory, as one run (see the
  moduledoc).

  ## Parameters
    - `strategy` - Conflict resolution strategy (default: :skip)

  ## Returns
    - `{:ok, %{definitions: [...], data: [...], unresolved_links: [...]}}`
  """
  @spec import_all(conflict_strategy()) :: {:ok, map()}
  def import_all(strategy \\ :skip) do
    Storage.list_entities()
    |> Enum.map(&file_unit(&1, strategy, fn _record, _i -> strategy end))
    |> run_units()
  end

  @doc """
  Imports selected entities and records based on user selections, as one
  run (see the moduledoc).

  ## Parameters
    - `selections` - Map of entity_name => %{definition: action, data: %{slug => action}}
      where action is :skip, :overwrite, or :merge

  ## Example

      selections = %{
        "brand" => %{
          definition: :overwrite,
          data: %{
            "acme-corp" => :overwrite,
            "globex" => :skip
          }
        }
      }

  ## Returns
    - `{:ok, %{definitions: [...], data: [...], unresolved_links: [...]}}`
  """
  @spec import_selected(map()) :: {:ok, map()}
  def import_selected(selections) when is_map(selections) do
    selections
    |> Enum.map(fn {entity_name, %{definition: def_action, data: data_actions}} ->
      file_unit(entity_name, selected(def_action), &record_selection(data_actions, &1, &2))
    end)
    |> run_units()
  end

  defp record_selection(data_actions, record, index) do
    slug = record["slug"]
    key = if is_nil(slug) or slug == "", do: "new-#{index}", else: slug
    data_actions |> Map.get(key, :skip) |> selected()
  end

  defp file_unit(entity_name, def_action, record_action) do
    with {:ok, json} <- read_entity_file(entity_name) do
      unit_from_json(json, def_action, record_action)
    end
  end

  # In a selection, :skip means "not selected": leave it untouched.
  defp selected(:skip), do: :leave
  defp selected(action), do: action

  defp unit_from_json(%{"definition" => definition, "data" => data}, def_action, record_action)
       when is_map(definition) and is_list(data),
       do: {:ok, unit(definition, data, def_action, record_action)}

  defp unit_from_json(_json, _def_action, _record_action), do: {:error, :invalid_format}

  # Files that could not be read are reported alongside the run's results.
  defp run_units(entries) do
    units = for {:ok, unit} <- entries, do: unit
    failed = for {:error, reason} <- entries, do: %{definition: {:error, reason}, data: []}
    {results, unresolved} = if units == [], do: {[], []}, else: run(units)
    results = results ++ failed

    {:ok,
     %{
       definitions: Enum.map(results, & &1.definition),
       data: Enum.flat_map(results, & &1.data),
       unresolved_links: unresolved
     }}
  end

  # ============================================================================
  # Preview / Dry Run
  # ============================================================================

  @doc """
  Previews what would be imported without making any changes.

  Returns data grouped by entity for the import UI, with each entity containing
  its definition preview and all data record previews.

  ## Returns

      %{
        entities: [
          %{
            name: "brand",
            definition: %{name: "brand", action: :create | :identical | :conflict},
            data: [%{slug: "acme", action: :create | :identical | :conflict}, ...]
          },
          ...
        ],
        summary: %{
          definitions: %{total: N, new: N, identical: N, conflicts: N},
          data: %{total: N, new: N, identical: N, conflicts: N}
        }
      }
  """
  @spec preview_import() :: map()
  def preview_import do
    entity_names = Storage.list_entities()

    entities =
      entity_names
      |> Enum.map(fn entity_name ->
        case Storage.read_entity(entity_name) do
          {:ok, %{"definition" => definition, "data" => data}} ->
            preview = preview_entity_file(entity_name, definition, data)

            %{
              name: entity_name,
              definition: preview.definition,
              data: preview.data
            }

          _ ->
            %{
              name: entity_name,
              definition: %{name: entity_name, action: :error},
              data: []
            }
        end
      end)

    # Calculate summary stats
    definition_previews = Enum.map(entities, & &1.definition)
    data_previews = Enum.flat_map(entities, & &1.data)

    %{
      entities: entities,
      summary: %{
        definitions: %{
          total: length(definition_previews),
          new: Enum.count(definition_previews, &(&1.action == :create)),
          identical: Enum.count(definition_previews, &(&1.action == :identical)),
          conflicts: Enum.count(definition_previews, &(&1.action == :conflict)),
          errors: Enum.count(definition_previews, &(&1.action == :error))
        },
        data: %{
          total: length(data_previews),
          new: Enum.count(data_previews, &(&1.action == :create)),
          identical: Enum.count(data_previews, &(&1.action == :identical)),
          conflicts: Enum.count(data_previews, &(&1.action == :conflict)),
          errors: Enum.count(data_previews, &(&1.action == :error))
        }
      }
    }
  end

  defp preview_entity_file(entity_name, definition, data) do
    existing_entity = Entities.get_entity_by_name(definition["name"])
    definition_preview = preview_definition(entity_name, existing_entity, definition)
    entity_uuid_for_slugs = if existing_entity, do: existing_entity.uuid, else: nil

    data_previews =
      preview_data_records(entity_name, existing_entity, entity_uuid_for_slugs, data)

    %{definition: definition_preview, data: data_previews}
  end

  defp preview_definition(entity_name, nil, _definition) do
    %{name: entity_name, action: :create}
  end

  defp preview_definition(entity_name, existing, definition) do
    if entity_definitions_match?(existing, definition) do
      %{name: entity_name, action: :identical, existing_uuid: existing.uuid}
    else
      %{name: entity_name, action: :conflict, existing_uuid: existing.uuid}
    end
  end

  defp preview_data_records(entity_name, existing_entity, entity_uuid_for_slugs, data) do
    {data_previews, _slug_counts} =
      data
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {record, index}, {previews, slug_counts} ->
        preview =
          preview_single_record(
            entity_name,
            existing_entity,
            entity_uuid_for_slugs,
            record,
            index,
            slug_counts
          )

        new_counts =
          if preview[:_base_slug] do
            Map.update(slug_counts, preview[:_base_slug], 1, &(&1 + 1))
          else
            slug_counts
          end

        {previews ++ [Map.delete(preview, :_base_slug)], new_counts}
      end)

    data_previews
  end

  defp preview_single_record(
         entity_name,
         _existing_entity,
         entity_uuid_for_slugs,
         record,
         index,
         slug_counts
       ) do
    slug = record["slug"]
    title = record["title"]

    if is_nil(slug) or slug == "" do
      preview_new_record_without_slug(
        entity_name,
        entity_uuid_for_slugs,
        title,
        index,
        slug_counts
      )
    else
      preview_record_with_slug(
        entity_name,
        entity_uuid_for_slugs,
        record,
        slug,
        title,
        slug_counts
      )
    end
  end

  defp preview_new_record_without_slug(
         entity_name,
         entity_uuid_for_slugs,
         title,
         index,
         slug_counts
       ) do
    base_slug = preview_generated_slug(title)
    import_key = "new-#{index}"

    display_generated =
      find_next_available_slug_preview(base_slug, entity_uuid_for_slugs, slug_counts)

    %{
      entity_name: entity_name,
      slug: import_key,
      display_slug: "(no slug)",
      title: title,
      generated_slug: display_generated,
      action: :create,
      is_new_record: true,
      _base_slug: base_slug
    }
  end

  defp preview_record_with_slug(entity_name, nil, _record, slug, title, _slug_counts) do
    # Entity will be created, so all data records will be new
    %{entity_name: entity_name, slug: slug, title: title, action: :create}
  end

  defp preview_record_with_slug(entity_name, entity_uuid, record, slug, title, slug_counts) do
    case EntityData.get_by_slug(entity_uuid, slug) do
      nil ->
        %{entity_name: entity_name, slug: slug, title: title, action: :create}

      existing ->
        new_slug_if_imported = find_next_available_slug_preview(slug, entity_uuid, slug_counts)
        action = if data_records_match?(existing, record), do: :identical, else: :conflict

        %{
          entity_name: entity_name,
          slug: slug,
          title: title,
          action: action,
          existing_uuid: existing.uuid,
          generated_slug: new_slug_if_imported
        }
    end
  end

  @doc """
  Detects all conflicts that would occur during import.

  ## Returns
    - `%{entity_conflicts: [...], data_conflicts: [...]}`
  """
  @spec detect_conflicts() :: map()
  def detect_conflicts do
    preview = preview_import()

    entity_conflicts =
      preview.entities
      |> Enum.filter(&(&1.definition.action == :conflict))
      |> Enum.map(& &1.name)

    data_conflicts =
      preview.entities
      |> Enum.flat_map(fn entity ->
        entity.data
        |> Enum.filter(&(&1.action == :conflict))
        |> Enum.map(&{entity.name, &1.slug})
      end)

    %{
      entity_conflicts: entity_conflicts,
      data_conflicts: data_conflicts
    }
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_default_user_uuid do
    case get_default_user() do
      nil -> nil
      user -> user.uuid
    end
  end

  defp get_default_user do
    case Auth.get_first_admin() do
      nil -> Auth.get_first_user()
      admin -> admin
    end
  end

  defp merge_fields_definition(existing, new) when is_list(existing) and is_list(new) do
    existing_map =
      existing
      |> Enum.map(fn field -> {field["key"], field} end)
      |> Map.new()

    new
    |> Enum.reduce(existing_map, fn new_field, acc ->
      key = new_field["key"]

      case Map.get(acc, key) do
        nil ->
          Map.put(acc, key, new_field)

        existing_field ->
          merged = Map.merge(existing_field, new_field)
          Map.put(acc, key, merged)
      end
    end)
    |> Map.values()
  end

  defp merge_fields_definition(_, new) when is_list(new), do: new
  defp merge_fields_definition(existing, _) when is_list(existing), do: existing
  defp merge_fields_definition(_, _), do: []

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _k, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)

      _k, _left_val, right_val ->
        right_val
    end)
  end

  defp deep_merge(_left, right), do: right

  # Check if existing entity definition matches imported definition
  defp entity_definitions_match?(existing, imported) do
    existing.display_name == imported["display_name"] and
      existing.display_name_plural == imported["display_name_plural"] and
      existing.description == imported["description"] and
      existing.icon == imported["icon"] and
      to_string(existing.status) == (imported["status"] || "published") and
      normalize_list(Relations.export_fields(existing.fields_definition)) ==
        normalize_list(imported["fields_definition"]) and
      normalize_map(existing.settings) == normalize_map(imported["settings"])
  end

  # Check if existing data record matches imported record
  defp data_records_match?(existing, imported) do
    existing.title == imported["title"] and
      existing.slug == imported["slug"] and
      to_string(existing.status) == (imported["status"] || "published") and
      normalize_map(exported_data(existing)) == normalize_map(imported["data"]) and
      normalize_map(existing.metadata) == normalize_map(imported["metadata"])
  end

  # A record's data as the exporter would write it — relation links as
  # slug refs — so an unchanged record compares identical to its file.
  defp exported_data(%EntityData{entity_uuid: entity_uuid, data: data}) do
    case Entities.get_entity(entity_uuid) do
      nil -> data
      entity -> entity |> Relations.export_data([data]) |> hd()
    end
  end

  # Normalize nil/null to empty map for comparison
  defp normalize_map(nil), do: %{}
  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_), do: %{}

  # Normalize nil/null to empty list for comparison
  defp normalize_list(nil), do: []
  defp normalize_list(list) when is_list(list), do: list
  defp normalize_list(_), do: []

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
