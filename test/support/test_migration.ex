defmodule PhoenixKitEntities.Test.Migration do
  @moduledoc """
  Wraps this module's migration coordinator so `Ecto.Migrator` can run it
  against the test database.

  In production a host runs `mix phoenix_kit.update`, which generates a
  migration whose `up/0` calls `PhoenixKitEntities.Migrations.up/1`. This
  module is that generated migration, checked in for the test suite — so the
  suite exercises exactly the DDL a real install gets, rather than trusting
  that statements which merely *look* right also parse and apply.

  It runs after core's chain has already created the two tables, which is the
  case V1 is written for: adoption of an existing table, then the marker.
  """

  use Ecto.Migration

  def up, do: PhoenixKitEntities.Migrations.up()

  def down, do: PhoenixKitEntities.Migrations.down()
end
