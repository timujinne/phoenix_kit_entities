defmodule Mix.Tasks.PhoenixKitEntities.ImportTest do
  @moduledoc """
  Tests for `mix phoenix_kit_entities.import`. Same shell-swap trick as
  Export. Every option is checked by what ended up in the database and
  which directory was read — the configured one, or `--input`'s for that
  run only.
  """
  use PhoenixKitEntities.DataCase, async: false

  alias Mix.Tasks.PhoenixKitEntities.Import
  alias PhoenixKit.Settings
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Mirror.Storage
  alias PhoenixKitEntities.Test.MirrorDir

  @tmp_root MirrorDir.path("import_task_test")
  # Outside the boundary the mirror-path SETTING is held to: only `--input`
  # can reach it.
  @other_root Path.join(System.tmp_dir!(), "phoenix_kit_entities_import_task_other")

  setup do
    File.rm_rf!(@tmp_root)
    File.rm_rf!(@other_root)
    File.mkdir_p!(@tmp_root)
    MirrorDir.use!(@tmp_root)

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
      File.rm_rf!(@tmp_root)
      File.rm_rf!(@other_root)
    end)

    # Pre-seed a user so the importer's default-creator lookup
    # resolves (same trick as importer_test.exs).
    user_uuid = Ecto.UUID.generate()

    {:ok, _} =
      Repo.query(
        "INSERT INTO phoenix_kit_users (uuid, email, hashed_password, is_active, account_type, inserted_at, updated_at) " <>
          "VALUES ($1::uuid, $2, $3, true, 'person', NOW(), NOW()) ON CONFLICT (uuid) DO NOTHING",
        [Ecto.UUID.dump!(user_uuid), "import-task-test@example.com", valid_test_password_hash()]
      )

    # The configured mirror directory holds one entity file; a second
    # directory, which only `--input` can reach, holds a different one.
    File.write!(Path.join(@tmp_root, "import_task_widget.json"), Jason.encode!(payload("widget")))
    File.mkdir_p!(@other_root)

    File.write!(
      Path.join(@other_root, "import_task_gadget.json"),
      Jason.encode!(payload("gadget"))
    )

    {:ok, user_uuid: user_uuid}
  end

  defp payload(kind, overrides \\ %{}) do
    %{
      "definition" =>
        Map.merge(
          %{
            "name" => "import_task_#{kind}",
            "display_name" => "Import Task #{kind}",
            "display_name_plural" => "Import Task #{kind}s",
            "description" => "From import",
            "icon" => "hero-puzzle-piece",
            "status" => "published",
            "fields_definition" => [
              %{"type" => "text", "key" => "title", "label" => "Title"},
              %{"type" => "text", "key" => "note", "label" => "Note"}
            ],
            "settings" => %{}
          },
          overrides["definition"] || %{}
        ),
      "data" => [
        Map.merge(
          %{
            "title" => "Imported alpha",
            "slug" => "alpha",
            "status" => "published",
            "data" => %{"title" => "Imported alpha"},
            "metadata" => %{}
          },
          overrides["record"] || %{}
        )
      ]
    }
  end

  defp rewrite_widget(overrides) do
    File.write!(
      Path.join(@tmp_root, "import_task_widget.json"),
      Jason.encode!(payload("widget", overrides))
    )
  end

  defp entity(kind), do: Entities.get_entity_by_name("import_task_#{kind}")

  defp record(kind) do
    case entity(kind) do
      nil -> nil
      entity -> EntityData.get_by_slug(entity.uuid, "alpha")
    end
  end

  defp info_lines do
    {:messages, messages} = Process.info(self(), :messages)
    for {:mix_shell, :info, [line]} <- messages, do: line
  end

  defp mirror_setting, do: Settings.get_setting("entities_mirror_path", "")

  @changed %{
    "definition" => %{"display_name" => "Renamed widget"},
    "record" => %{"title" => "Renamed alpha", "data" => %{"note" => "added"}}
  }

  describe "run/1 against the configured directory" do
    test "dry-run reports conflicts using existing record uuids" do
      Import.run(["-y", "-q"])
      rewrite_widget(@changed)

      Import.run(["--dry-run"])

      assert Enum.any?(
               info_lines(),
               &String.contains?(&1, "[CHANGED] import_task_widget (existing id:")
             )

      assert Enum.any?(
               info_lines(),
               &String.contains?(&1, "[CHANGED] import_task_widget/alpha (existing id:")
             )
    end

    test "without -y it asks first, and 'no' imports nothing" do
      send(self(), {:mix_shell_input, :yes?, false})

      assert catch_exit(Import.run([])) == {:shutdown, 0}

      assert_received {:mix_shell, :info, ["Import cancelled."]}
      assert entity("widget") == nil
    end

    test "-y imports the definition and its records from that directory" do
      Import.run(["-y"])

      assert %{display_name: "Import Task widget"} = entity("widget")
      assert %{title: "Imported alpha", data: %{"title" => "Imported alpha"}} = record("widget")
      # The other directory was not read.
      assert entity("gadget") == nil

      assert "  Definition 'import_task_widget' created" in info_lines()
      assert "  Data 'alpha' created" in info_lines()
      assert "Created: 2" in info_lines()
    end

    test "--on-conflict skip leaves an existing definition and record as they are" do
      Import.run(["-y", "-q"])
      rewrite_widget(@changed)

      Import.run(["--on-conflict", "skip", "-y"])

      assert entity("widget").display_name == "Import Task widget"
      assert record("widget").title == "Imported alpha"
      assert "Skipped: 2" in info_lines()
    end

    test "--on-conflict overwrite replaces them with the file's values" do
      Import.run(["-y", "-q"])
      rewrite_widget(@changed)

      Import.run(["--on-conflict", "overwrite", "-y"])

      assert entity("widget").display_name == "Renamed widget"
      assert %{title: "Renamed alpha", data: %{"note" => "added"}} = record("widget")
      assert "Updated: 2" in info_lines()
    end

    test "--on-conflict merge adds the file's values to the stored ones" do
      Import.run(["-y", "-q"])
      rewrite_widget(@changed)

      Import.run(["--on-conflict", "merge", "-y"])

      assert entity("widget").display_name == "Renamed widget"

      assert %{title: "Renamed alpha", data: %{"title" => "Imported alpha", "note" => "added"}} =
               record("widget")
    end

    test "--on-conflict bogus exits non-zero before importing anything" do
      assert catch_exit(Import.run(["--on-conflict", "bogus", "-y"])) == {:shutdown, 1}

      assert_received {:mix_shell, :error, ["Invalid conflict strategy: bogus"]}
      assert entity("widget") == nil
    end

    test "--dry-run names the directory and what it would do, and writes nothing" do
      Import.run(["--dry-run"])

      assert "Previewing import (dry-run)..." in info_lines()
      assert "Source path: #{@tmp_root}\n" in info_lines()
      assert "  [NEW] import_task_widget" in info_lines()
      assert "  [NEW] import_task_widget/alpha" in info_lines()
      assert entity("widget") == nil
    end

    test "--quiet --dry-run prints nothing" do
      Import.run(["--dry-run", "--quiet"])

      assert info_lines() == []
      assert entity("widget") == nil
    end

    test "--entity NAME imports that entity only" do
      File.write!(
        Path.join(@tmp_root, "import_task_extra.json"),
        Jason.encode!(payload("extra"))
      )

      Import.run(["--entity", "import_task_widget", "-y"])

      assert %{} = entity("widget")
      assert %{title: "Imported alpha"} = record("widget")
      assert entity("extra") == nil
    end

    test "--entity for a name with no file exits non-zero" do
      assert catch_exit(Import.run(["--entity", "import_task_ghost", "-y"])) == {:shutdown, 1}

      assert_received {:mix_shell, :error, ["File not found for entity 'import_task_ghost'"]}
    end
  end

  describe "run/1 with --input" do
    test "reads that directory instead, and leaves the setting alone" do
      Import.run(["--input", @other_root, "-y"])

      assert %{display_name: "Import Task gadget"} = entity("gadget")
      assert %{title: "Imported alpha"} = record("gadget")
      # The configured directory was not read, and is still configured.
      assert entity("widget") == nil
      assert mirror_setting() == @tmp_root
      assert Storage.root_path() == @tmp_root
    end

    test "--dry-run reports the directory it was given" do
      Import.run(["--input", @other_root, "--dry-run"])

      assert "Source path: #{@other_root}\n" in info_lines()
      assert "  [NEW] import_task_gadget" in info_lines()
      refute "  [NEW] import_task_widget" in info_lines()
    end

    test "a directory that does not exist exits non-zero and imports nothing" do
      missing = Path.join(@other_root, "nope")

      assert catch_exit(Import.run(["--input", missing, "-y"])) == {:shutdown, 1}

      assert_received {:mix_shell, :error, ["Input directory not found: " <> ^missing]}
      assert entity("widget") == nil
      assert mirror_setting() == @tmp_root
    end

    test "short aliases -c / -i / -q / -y do the same" do
      Import.run(["-i", @other_root, "-y", "-q"])

      File.write!(
        Path.join(@other_root, "import_task_gadget.json"),
        Jason.encode!(payload("gadget", %{"definition" => %{"display_name" => "Renamed gadget"}}))
      )

      Import.run(["-c", "overwrite", "-i", @other_root, "-q", "-y"])

      assert entity("gadget").display_name == "Renamed gadget"
      assert info_lines() == []
      assert mirror_setting() == @tmp_root
    end

    test "an empty directory imports nothing and says so" do
      empty_dir = Path.join(@other_root, "empty")
      File.mkdir_p!(empty_dir)

      Import.run(["--input", empty_dir, "-y"])

      assert "Found 0 entities with 0 total data records" in info_lines()
      assert "Created: 0" in info_lines()
      assert Entities.list_entities() == []
    end
  end
end
