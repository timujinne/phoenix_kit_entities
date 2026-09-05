defmodule PhoenixKitEntities.MigrationsRuntimeTest do
  @moduledoc """
  Exercises `PhoenixKitEntities.Migrations.migrated_version_runtime/1` against
  a real `phoenix_kit_entities` table comment, since `marker_to_version/1`'s
  catch-all (foreign marker prefix, deprecation-style prose, malformed
  `pkn_schema:` payload) had zero coverage.

  Each test stamps the comment directly and relies on the DataCase sandbox
  transaction to roll it back, so this never touches the table's real
  `pkn_schema:` state outside the test.
  """
  use PhoenixKitEntities.DataCase, async: false

  alias PhoenixKitEntities.Migrations

  describe "migrated_version_runtime/1" do
    test "returns 0 when no marker has ever been stamped" do
      Repo.query!("COMMENT ON TABLE public.phoenix_kit_entities IS NULL")

      assert Migrations.migrated_version_runtime(prefix: "public") == 0
    end

    test "returns 0 for a foreign module's marker prefix" do
      Repo.query!("COMMENT ON TABLE public.phoenix_kit_entities IS 'pkb_schema:1'")

      assert Migrations.migrated_version_runtime(prefix: "public") == 0
    end

    test "returns 0 for deprecation-style prose left on the table" do
      Repo.query!(
        "COMMENT ON TABLE public.phoenix_kit_entities IS 'deprecated 2026-09-05: superseded by core V183'"
      )

      assert Migrations.migrated_version_runtime(prefix: "public") == 0
    end

    test "returns 0 for a malformed pkn_schema payload" do
      Repo.query!("COMMENT ON TABLE public.phoenix_kit_entities IS 'pkn_schema:abc'")

      assert Migrations.migrated_version_runtime(prefix: "public") == 0
    end

    test "returns 1 for the real pkn_schema:1 marker" do
      Repo.query!("COMMENT ON TABLE public.phoenix_kit_entities IS 'pkn_schema:1'")

      assert Migrations.migrated_version_runtime(prefix: "public") == 1
    end
  end
end
