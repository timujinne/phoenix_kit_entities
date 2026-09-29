defmodule PhoenixKitEntities.ActivityLogRescueTest do
  @moduledoc """
  `PhoenixKitEntities.ActivityLog.log/1` hands the entry to core's
  `PhoenixKit.Activity.log/1` with the `"entities"` module key and is
  always `:ok`: core logs a failure and returns it, so a mutation never
  fails on its audit row.

  This file is `async: false` because it `DROP TABLE`s
  `phoenix_kit_activities` inside the sandboxed transaction (rolled back at
  test exit).
  """
  use PhoenixKitEntities.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitEntities.ActivityLog

  test "an entry carries the entities module key" do
    uuid = Ecto.UUID.generate()

    assert :ok =
             ActivityLog.log(%{
               action: "entity.smoke",
               resource_type: "entity",
               resource_uuid: uuid
             })

    assert [["entities"]] =
             Repo.query!(
               "SELECT module FROM phoenix_kit_activities WHERE resource_uuid = $1::text::uuid",
               [uuid]
             ).rows
  end

  test "a missing activities table is logged by core, never raised" do
    Repo.query!("DROP TABLE IF EXISTS phoenix_kit_activities CASCADE")

    log =
      capture_log(fn ->
        assert :ok =
                 ActivityLog.log(%{
                   action: "entity.created",
                   resource_type: "entity",
                   resource_uuid: Ecto.UUID.generate(),
                   metadata: %{"name" => "rescue_test"}
                 })
      end)

    assert log =~ "Activity logging error"
  end

  test "a process with no sandbox connection gets :ok, not a raise" do
    task =
      Task.async(fn ->
        ActivityLog.log(%{
          action: "entity.crossing",
          resource_type: "entity",
          resource_uuid: Ecto.UUID.generate()
        })
      end)

    capture_log(fn -> assert :ok = Task.await(task, 1_000) end)
  end

  test "a map core cannot turn into an entry is :ok too" do
    capture_log(fn -> assert :ok = ActivityLog.log(DateTime.utc_now()) end)
  end
end
