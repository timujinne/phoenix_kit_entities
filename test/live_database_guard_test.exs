defmodule PhoenixKitEntities.LiveDatabaseGuardTest do
  @moduledoc """
  S014: pure unit coverage for `check!/1`'s own decision — separate from
  `LiveDatabaseGuardWiringTest`, which proves the module is actually
  reachable from `test_helper.exs`'s real boot sequence, not just that its
  logic is correct in isolation.
  """
  use ExUnit.Case

  alias PhoenixKitEntities.Test.LiveDatabaseGuard

  describe "check!/1 — name-shape rule" do
    test "accepts a name ending in `_test`" do
      assert :ok = LiveDatabaseGuard.check!("foo_test")
    end

    test "accepts a name ending in `_test` followed by digits" do
      assert :ok = LiveDatabaseGuard.check!("foo_test2")
    end

    test "refuses a name that looks like a dev database" do
      assert_raise LiveDatabaseGuard.LiveDatabaseError, ~r/foo_dev/, fn ->
        LiveDatabaseGuard.check!("foo_dev")
      end
    end

    test "refuses a bare name with no `_test` suffix at all" do
      assert_raise LiveDatabaseGuard.LiveDatabaseError, ~r/foo/, fn ->
        LiveDatabaseGuard.check!("foo")
      end
    end

    test "the raised message says WHY, not just which database" do
      assert_raise LiveDatabaseGuard.LiveDatabaseError,
                   ~r/does not look like a test database/,
                   fn -> LiveDatabaseGuard.check!("foo_dev") end
    end
  end

  describe "check!/1 — PHOENIX_KIT_LIVE_DATABASES rule" do
    setup do
      previous = System.get_env("PHOENIX_KIT_LIVE_DATABASES")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env("PHOENIX_KIT_LIVE_DATABASES")
          value -> System.put_env("PHOENIX_KIT_LIVE_DATABASES", value)
        end
      end)

      :ok
    end

    test "refuses a listed name even when it ends in `_test`" do
      System.put_env("PHOENIX_KIT_LIVE_DATABASES", "shared_fleet_test,other_test")

      assert_raise LiveDatabaseGuard.LiveDatabaseError, ~r/shared_fleet_test/, fn ->
        LiveDatabaseGuard.check!("shared_fleet_test")
      end
    end

    test "does not refuse a `_test`-shaped name absent from the list" do
      System.put_env("PHOENIX_KIT_LIVE_DATABASES", "shared_fleet_test")

      assert :ok = LiveDatabaseGuard.check!("unrelated_test")
    end

    test "an unset variable refuses nothing extra beyond the shape rule" do
      System.delete_env("PHOENIX_KIT_LIVE_DATABASES")

      assert :ok = LiveDatabaseGuard.check!("phoenix_kit_entities_test")
    end
  end
end
