defmodule Mix.Tasks.PhoenixKitEntities.ExportTest do
  @moduledoc """
  Tests for `mix phoenix_kit_entities.export`.

  `Mix.Task.run("app.start")` is a no-op when the app is already
  started (which is the case in our test env), so the task body runs
  cleanly inside the test sandbox. We swap `Mix.shell()` to
  `Mix.Shell.Process` to capture output via `assert_received` and
  silence the otherwise-noisy IO.
  """
  use PhoenixKitEntities.DataCase, async: false

  alias Mix.Tasks.PhoenixKitEntities.Export
  alias PhoenixKit.Settings
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Mirror.Storage
  alias PhoenixKitEntities.Test.MirrorDir

  @tmp_root MirrorDir.path("export_task_test")
  # Outside the boundary the mirror-path SETTING is held to: only `--output`
  # can reach it.
  @other_root Path.join(System.tmp_dir!(), "phoenix_kit_entities_export_task_other")

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    MirrorDir.use!(@tmp_root)
    {:ok, _} = Settings.update_setting("entities_mirror_definitions_enabled", "true")

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
      File.rm_rf!(@tmp_root)
    end)

    actor_uuid = Ecto.UUID.generate()

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "export_task_widget",
          display_name: "Export Task Widget",
          display_name_plural: "Export Task Widgets",
          fields_definition: [%{"type" => "text", "key" => "title", "label" => "Title"}],
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, _other} =
      Entities.create_entity(
        %{
          name: "export_task_gadget",
          display_name: "Export Task Gadget",
          display_name_plural: "Export Task Gadgets",
          fields_definition: [%{"type" => "text", "key" => "title", "label" => "Title"}],
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, _record} =
      EntityData.create(%{
        entity_uuid: entity.uuid,
        title: "Alpha",
        slug: "alpha",
        data: %{"title" => "Alpha"},
        created_by_uuid: actor_uuid
      })

    {:ok, entity: entity, actor_uuid: actor_uuid}
  end

  defp exported(dir \\ @tmp_root, name) do
    path = Path.join(dir, "#{name}.json")
    if File.exists?(path), do: path |> File.read!() |> Jason.decode!()
  end

  defp files(dir), do: dir |> File.ls!() |> Enum.sort()

  defp info_lines do
    {:messages, messages} = Process.info(self(), :messages)
    for {:mix_shell, :info, [line]} <- messages, do: line
  end

  describe "run/1 into the configured directory" do
    test "no flags writes one file per entity, without records while data mirroring is off" do
      Export.run([])

      assert files(@tmp_root) == ["export_task_gadget.json", "export_task_widget.json"]

      assert %{"definition" => %{"name" => "export_task_widget"}, "data" => []} =
               exported("export_task_widget")

      assert "Exporting all entities..." in info_lines()
      assert "Exported: 2 entities" in info_lines()
      assert "Output path: #{@tmp_root}" in info_lines()
    end

    test "the data-mirroring setting decides whether records are included" do
      Settings.update_setting("entities_mirror_data_enabled", "true")

      Export.run(["-q"])

      assert [%{"slug" => "alpha", "title" => "Alpha"}] = exported("export_task_widget")["data"]
    end

    test "--with-data includes records although the setting is off" do
      Settings.update_setting("entities_mirror_data_enabled", "false")

      Export.run(["--with-data"])

      assert [%{"slug" => "alpha", "data" => %{"title" => "Alpha"}}] =
               exported("export_task_widget")["data"]
    end

    test "--with-data exports portable relation targets and links", ctx do
      target_entity = Entities.get_entity_by_name("export_task_gadget")

      {:ok, target} =
        EntityData.create(%{
          entity_uuid: target_entity.uuid,
          title: "Linked gadget",
          slug: "linked-gadget",
          created_by_uuid: ctx.actor_uuid
        })

      relation = %{
        "type" => "relation",
        "key" => "gadget",
        "label" => "Gadget",
        "target_entity" => target_entity.uuid
      }

      {:ok, _} =
        Entities.update_entity(ctx.entity, %{
          fields_definition: ctx.entity.fields_definition ++ [relation]
        })

      record = EntityData.get_by_slug(ctx.entity.uuid, "alpha")
      {:ok, _} = EntityData.update(record, %{data: Map.put(record.data, "gadget", target.uuid)})

      Export.run(["--with-data"])

      content = exported("export_task_widget")

      assert List.last(content["definition"]["fields_definition"])["target_entity"] ==
               target_entity.name

      assert hd(content["data"])["data"]["gadget"] == %{"slug" => "linked-gadget"}
    end

    test "--no-data leaves records out although the setting is on" do
      Settings.update_setting("entities_mirror_data_enabled", "true")

      Export.run(["--no-data"])

      assert exported("export_task_widget")["data"] == []
    end

    test "--entity NAME writes that entity's file only", ctx do
      Export.run(["--entity", ctx.entity.name])

      assert files(@tmp_root) == ["export_task_widget.json"]
    end

    test "-e is --entity", ctx do
      Export.run(["-e", ctx.entity.name])

      assert files(@tmp_root) == ["export_task_widget.json"]
    end

    test "--entity for an unknown name exits non-zero and writes nothing" do
      assert catch_exit(Export.run(["--entity", "export_task_ghost"])) == {:shutdown, 1}

      assert_received {:mix_shell, :error, ["Entity 'export_task_ghost' not found."]}
      assert files(@tmp_root) == []
    end

    test "--quiet and -q print nothing and still export" do
      Export.run(["--quiet"])
      Export.run(["-q"])

      assert info_lines() == []
      assert files(@tmp_root) == ["export_task_gadget.json", "export_task_widget.json"]
    end
  end

  describe "run/1 with --output" do
    setup do
      File.rm_rf!(@other_root)
      on_exit(fn -> File.rm_rf!(@other_root) end)
    end

    test "writes into that directory, creating it, and leaves the setting alone" do
      Export.run(["--output", @other_root])

      assert files(@other_root) == ["export_task_gadget.json", "export_task_widget.json"]

      assert %{"definition" => %{"name" => "export_task_widget"}} =
               exported(@other_root, "export_task_widget")

      # Nothing went to the configured directory, and it is still configured.
      assert files(@tmp_root) == []
      assert Settings.get_setting("entities_mirror_path", "") == @tmp_root
      assert Storage.root_path() == @tmp_root
      assert "Output path: #{@other_root}" in info_lines()
    end

    test "-o is --output", ctx do
      Export.run(["-o", @other_root, "-e", ctx.entity.name])

      assert files(@other_root) == ["export_task_widget.json"]
      assert files(@tmp_root) == []
    end

    test "a directory that cannot be created exits non-zero and writes nothing" do
      File.mkdir_p!(@other_root)
      blocker = Path.join(@other_root, "a_file")
      File.write!(blocker, "")

      assert catch_exit(Export.run(["--output", Path.join(blocker, "sub")])) == {:shutdown, 1}

      assert_received {:mix_shell, :error, ["Cannot create output directory " <> _]}
      assert files(@tmp_root) == []
    end
  end
end
