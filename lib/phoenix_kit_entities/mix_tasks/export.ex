defmodule Mix.Tasks.PhoenixKitEntities.Export do
  @shortdoc "Export entities and entity data to JSON files"

  @moduledoc """
  Mix task to export entity definitions and data to JSON files.

  Each entity is exported as a single file containing both the definition
  and all its data records.

  Exports are stored in the configured mirror path (default: priv/entities/).

  ## Usage

      # Export all entities (definitions + data if data mirroring enabled)
      mix phoenix_kit_entities.export

      # Export specific entity
      mix phoenix_kit_entities.export --entity brand

      # Export with data included (regardless of setting)
      mix phoenix_kit_entities.export --with-data

      # Export without data (regardless of setting)
      mix phoenix_kit_entities.export --no-data

      # Custom output path
      mix phoenix_kit_entities.export --output /path/to/export

  ## Options

      --entity NAME        Export specific entity only
      --with-data          Include data records in export
      --no-data            Exclude data records from export
      --output PATH        Custom output directory (overrides settings)
      --quiet              Suppress output messages

  ## Output Structure

      priv/entities/
        brand.json       # Contains definition + all data records
        product.json     # Contains definition + all data records

  ## JSON Format

      {
        "export_version": "1.0",
        "exported_at": "2025-12-11T10:30:00Z",
        "definition": {
          "name": "brand",
          "display_name": "Brand",
          ...
        },
        "data": [
          {"title": "Acme Corp", "slug": "acme-corp", ...},
          {"title": "Globex", "slug": "globex", ...}
        ]
      }

  ## Examples

      # Full export for version control backup
      mix phoenix_kit_entities.export --with-data

      # Export just the brand entity
      mix phoenix_kit_entities.export --entity brand

      # Export to a specific directory
      mix phoenix_kit_entities.export --output ./backup/entities
  """

  use Mix.Task

  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Mirror.{Exporter, Storage}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {options, _remaining} = parse_options(args)

    # `--output` names the directory for THIS run (`Storage.with_root/2`);
    # the `entities_mirror_path` setting is left alone. An operator's own
    # path is not held to the setting's containment rule — see
    # `Storage.with_root/2`.
    case options[:output] do
      nil -> run_export(options)
      output_path -> Storage.with_root(output_path, fn -> run_export(options) end)
    end
  end

  defp run_export(options) do
    case Storage.ensure_directory() do
      :ok ->
        :ok

      {:error, {:mkdir_failed, path, reason}} ->
        Mix.shell().error("Cannot create output directory #{path}: #{:file.format_error(reason)}")
        exit({:shutdown, 1})
    end

    if options[:entity] do
      export_single_entity(options[:entity], options)
    else
      export_all(options)
    end
  end

  defp parse_options(args) do
    {options, remaining, _errors} =
      OptionParser.parse(args,
        strict: [
          entity: :string,
          with_data: :boolean,
          no_data: :boolean,
          output: :string,
          quiet: :boolean
        ],
        aliases: [
          e: :entity,
          o: :output,
          q: :quiet
        ]
      )

    {Enum.into(options, %{}), remaining}
  end

  defp include_data?(options) do
    cond do
      options[:with_data] -> true
      options[:no_data] -> false
      true -> Storage.data_enabled?()
    end
  end

  defp export_single_entity(entity_name, options) do
    case Entities.get_entity_by_name(entity_name) do
      nil ->
        Mix.shell().error("Entity '#{entity_name}' not found.")
        exit({:shutdown, 1})

      entity ->
        include_data = include_data?(options)
        result = export_entity(entity, include_data)
        log_result(entity_name, exported_count(entity, include_data, options), result, options)
        log_summary([result], options)
    end
  end

  defp export_all(options) do
    unless options[:quiet] do
      Mix.shell().info("Exporting all entities...")
    end

    include_data = include_data?(options)

    entities = Entities.list_entities()

    counts =
      if include_data and options[:quiet] != true,
        do: EntityData.counts_by_entities(Enum.map(entities, & &1.uuid)),
        else: %{}

    results =
      Enum.map(entities, fn entity ->
        result = export_entity(entity, include_data)
        log_result(entity.name, Map.get(counts, entity.uuid, 0), result, options)
        result
      end)

    log_summary(results, options)
  end

  defp exported_count(_entity, _include_data, %{quiet: true}), do: 0
  defp exported_count(entity, true, _options), do: EntityData.count_by_entity(entity.uuid)
  defp exported_count(_entity, false, _options), do: 0

  # The CLI uses the same portable relation and multilang serialization as
  # automatic mirrors, while its flags decide whether data is included.
  defp export_entity(entity, include_data) do
    case Exporter.export_entity(entity, include_data: include_data) do
      {:ok, path, _mode} -> {:ok, path}
      {:error, _reason} = error -> error
    end
  end

  defp log_result(_name, _data_count, _result, %{quiet: true}), do: :ok

  defp log_result(name, data_count, {:ok, path}, _options) do
    data_info = if data_count > 0, do: " (#{data_count} records)", else: ""
    Mix.shell().info("  #{name}#{data_info} -> #{path}")
  end

  defp log_result(name, _data_count, {:error, reason}, _options) do
    Mix.shell().error("  #{name} failed: #{inspect(reason)}")
  end

  defp log_summary(_results, %{quiet: true}), do: :ok

  defp log_summary(results, _options) do
    success_count = Enum.count(results, &match?({:ok, _}, &1))
    error_count = Enum.count(results, &match?({:error, _}, &1))

    Mix.shell().info("\n--- Summary ---")
    Mix.shell().info("Exported: #{success_count} entities")

    if error_count > 0 do
      Mix.shell().error("Errors: #{error_count}")
    end

    Mix.shell().info("Output path: #{Storage.root_path()}")
  end
end
