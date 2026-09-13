defmodule PhoenixKitEntities.MigrationsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEntities.Migrations

  @tables ~w(phoenix_kit_entities phoenix_kit_entity_data)

  @indexes ~w(
    phoenix_kit_entities_created_by_uuid_idx
    phoenix_kit_entities_name_uidx
    phoenix_kit_entities_status_idx
    phoenix_kit_entities_uuid_idx
    phoenix_kit_entity_data_created_by_uuid_idx
    phoenix_kit_entity_data_entity_position_idx
    phoenix_kit_entity_data_entity_uuid_idx
    phoenix_kit_entity_data_parent_index
    phoenix_kit_entity_data_slug_idx
    phoenix_kit_entity_data_status_idx
    phoenix_kit_entity_data_title_idx
    phoenix_kit_entity_data_uuid_idx
  )

  @constraints ~w(
    phoenix_kit_entities_pkey
    phoenix_kit_entity_data_pkey
    fk_entity_data_entity_uuid
    phoenix_kit_entity_data_parent_uuid_fkey
  )

  test "chain is V1 and marks phoenix_kit_entities" do
    assert Migrations.current_version() == 1
    assert Migrations.version_table() == "phoenix_kit_entities"
  end

  test "up_statements creates every owned table idempotently and stamps the marker" do
    stmts = Migrations.up_statements("public")

    for t <- @tables do
      assert Enum.any?(stmts, &String.contains?(&1, "CREATE TABLE IF NOT EXISTS public.#{t} ("))
    end

    assert List.last(stmts) == "COMMENT ON TABLE public.phoenix_kit_entities IS 'pkn_schema:1'"
  end

  test "no statement can destroy data, in either direction" do
    all = Migrations.up_statements("public") ++ Migrations.down_statements("public", 0)

    for s <- all do
      # `ON DELETE CASCADE|RESTRICT|SET NULL` is core's own FK referential
      # action, copied verbatim from the dump authority — not a DROP/
      # TRUNCATE/DELETE statement. Strip it before scanning for the real
      # destructive verbs the Global Constraints forbid.
      scanned =
        Regex.replace(~r/ON DELETE (CASCADE|RESTRICT|SET NULL|SET DEFAULT|NO ACTION)/i, s, "")

      refute scanned =~ ~r/\b(DROP|TRUNCATE|DELETE)\b/i, "destructive statement: #{s}"
      refute scanned =~ ~r/ALTER TABLE .* DROP/i, "destructive statement: #{s}"
    end
  end

  test "every CREATE INDEX and constraint is guarded" do
    for s <- Migrations.up_statements("public"), s =~ ~r/CREATE (UNIQUE )?INDEX/ do
      assert s =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS/
    end

    for s <- Migrations.up_statements("public"), s =~ ~r/ADD CONSTRAINT/ do
      assert s =~ ~r/DO \$\$/ and s =~ ~r/IF NOT EXISTS/
    end
  end

  test "every pinned index and constraint name is present in up_statements" do
    stmts = Migrations.up_statements("public")
    joined = Enum.join(stmts, "\n")

    for name <- @indexes do
      assert joined =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS #{name}\b/,
             "missing index: #{name}"
    end

    for name <- @constraints do
      assert joined =~ ~r/ADD CONSTRAINT #{name}\b/, "missing constraint: #{name}"
    end
  end

  test "down only rewrites the marker" do
    assert Migrations.down_statements("public", 0) ==
             ["COMMENT ON TABLE public.phoenix_kit_entities IS NULL"]

    assert Migrations.down_statements("public", 1) ==
             ["COMMENT ON TABLE public.phoenix_kit_entities IS 'pkn_schema:1'"]
  end

  test "prefix is validated before it reaches DDL" do
    assert_raise ArgumentError, fn -> Migrations.up_statements("public; DROP") end
  end

  test "the module registers the chain" do
    assert PhoenixKitEntities.migration_module() == Migrations
  end

  # The drift guard. Core's ExpectedSchema manifest is the authority for what
  # these two tables contain; V1 adopts that shape. Two lists that must stay in
  # sync, so derive one from the other instead of hand-copying: a column, index
  # or constraint core adds to an entities table and this chain does not adopt
  # is a silently missing object on any install whose core baseline stops
  # creating it.
  #
  # `ExpectedSchema` is core-internal (`@moduledoc false`), so the test skips
  # itself rather than failing if a future core drops `objects/1`.
  describe "adoption covers core's manifest" do
    @manifest_mod PhoenixKit.Migrations.ExpectedSchema

    test "every required core object for the entities tables is in up_statements" do
      if Code.ensure_loaded?(@manifest_mod) and function_exported?(@manifest_mod, :objects, 1) do
        stmts = Migrations.up_statements("public")

        for %{id: id, presence: :required} <- @manifest_mod.objects("public"),
            [class, rest] = String.split(id, ":", parts: 2),
            owned_object?(rest) do
          assert covered?(class, rest, stmts), "V1 does not adopt core's #{id}"
        end
      end
    end
  end

  defp owned_object?(rest) do
    Enum.any?(@tables, fn t ->
      rest == t or String.starts_with?(rest, t <> ".") or String.starts_with?(rest, t <> "_")
    end)
  end

  defp covered?("table", table, stmts),
    do: Enum.any?(stmts, &String.contains?(&1, "CREATE TABLE IF NOT EXISTS public.#{table} ("))

  defp covered?("column", id, stmts) do
    [table, column] = String.split(id, ".", parts: 2)

    stmts
    |> Enum.filter(&String.contains?(&1, "CREATE TABLE IF NOT EXISTS public.#{table} ("))
    |> Enum.any?(&Regex.match?(~r/^\s+"?#{Regex.escape(column)}"?\s/m, &1))
  end

  defp covered?("index", name, stmts),
    do: Enum.any?(stmts, &String.contains?(&1, "INDEX IF NOT EXISTS #{name} ON"))

  defp covered?("constraint", id, stmts) do
    [_table, name] = String.split(id, ".", parts: 2)
    Enum.any?(stmts, &String.contains?(&1, "ADD CONSTRAINT #{name} "))
  end

  defp covered?(_class, _id, _stmts), do: true
end
