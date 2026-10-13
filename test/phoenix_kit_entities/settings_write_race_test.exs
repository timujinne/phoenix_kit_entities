defmodule PhoenixKitEntities.SettingsWriteRaceTest do
  @moduledoc """
  Settings writers against a second writer on its own database connection.

  The sandbox hands every process one shared transaction, where a row lock
  never blocks, so these tests run unboxed: each writer holds a real
  connection, the rows are committed, and `on_exit` removes them.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.Test.Repo

  setup do
    Sandbox.mode(Repo, :manual)
    name = "race_#{System.unique_integer([:positive])}"

    entity =
      unboxed(fn ->
        {:ok, entity} =
          Entities.create_entity(%{
            name: name,
            display_name: "Race",
            display_name_plural: "Races",
            status: "published",
            fields_definition: [%{"type" => "text", "key" => "name", "label" => "Name"}],
            created_by_uuid: Ecto.UUID.generate()
          })

        entity
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(e in Entities, where: e.uuid == ^entity.uuid))

        Repo.query!("DELETE FROM phoenix_kit_activities WHERE resource_uuid = $1", [
          Ecto.UUID.dump!(entity.uuid)
        ])
      end)
    end)

    {:ok, entity: entity}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Another admin's save: the row is written and held until `:commit`.
  defp hold_title_save(entity, test_pid) do
    Task.async(fn -> unboxed(fn -> write_and_wait(entity, test_pid) end) end)
  end

  defp write_and_wait(entity, test_pid) do
    Repo.transaction(fn -> write_then_hold(entity, test_pid) end)
  end

  defp write_then_hold(entity, test_pid) do
    from(e in Entities, where: e.uuid == ^entity.uuid)
    |> Repo.update_all(set: [settings: %{"public_form_title" => "Saved meanwhile"}])

    send(test_pid, :row_held)

    receive do
      :commit -> :ok
    end
  end

  # Returns once some backend of this database is waiting on a lock.
  defp await_blocked_writer(attempts \\ 200) do
    %{rows: [[waiting]]} =
      unboxed(fn ->
        Repo.query!("""
        SELECT count(*) FROM pg_stat_activity
        WHERE datname = current_database() AND wait_event_type = 'Lock'
        """)
      end)

    cond do
      waiting > 0 -> :ok
      attempts == 0 -> flunk("the second writer never reached the held row")
      true -> Process.sleep(10) && await_blocked_writer(attempts - 1)
    end
  end

  test "update_mirror_settings/3 keeps a setting saved while it waited for the row", ctx do
    other = hold_title_save(ctx.entity, self())
    assert_receive :row_held, 5_000

    # `ctx.entity` was loaded before the other admin's save.
    mirror =
      Task.async(fn ->
        unboxed(fn -> Entities.update_mirror_settings(ctx.entity, %{"mirror_data" => true}) end)
      end)

    await_blocked_writer()
    send(other.pid, :commit)

    assert {:ok, _} = Task.await(other)
    assert {:ok, updated} = Task.await(mirror)

    stored = unboxed(fn -> Entities.get_entity!(ctx.entity.uuid).settings end)

    assert stored == %{"public_form_title" => "Saved meanwhile", "mirror_data" => true}
    assert updated.settings == stored
  end

  test "an entity save waiting on a submission keeps the committed counters", ctx do
    test_pid = self()

    submission =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Entities.bump_public_form_stats(ctx.entity.uuid, ["total_submissions"])
            send(test_pid, :row_held)

            receive do
              :commit -> :ok
            end
          end)
        end)
      end)

    assert_receive :row_held, 5_000

    save =
      Task.async(fn ->
        unboxed(fn ->
          Entities.update_entity(ctx.entity, %{
            settings: %{"public_form_title" => "New title"}
          })
        end)
      end)

    await_blocked_writer()
    send(submission.pid, :commit)
    assert {:ok, _} = Task.await(submission)
    assert {:ok, updated} = Task.await(save)

    stored = unboxed(fn -> Entities.get_entity!(ctx.entity.uuid).settings end)
    assert stored["public_form_title"] == "New title"
    assert stored["public_form_stats"]["total_submissions"] == 1
    assert updated.settings == stored
  end
end
