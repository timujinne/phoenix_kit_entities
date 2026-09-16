defmodule PhoenixKitEntities.ManagedTest do
  @moduledoc """
  The managed-blueprint contract (catalogue attribute sets et al.):
  write-path guard, listing exclusion, cap exemption, delete guard.
  Pure-map + DB pins; the guard functions take any struct/map with
  `settings`/`name`/`status`, so most pins need no DB.
  """
  use PhoenixKitEntities.DataCase, async: false

  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Managed

  defp managed_entity(overrides \\ %{}) do
    Map.merge(
      %{
        name: "catalogue_set_ikea_colors",
        status: "published",
        settings: %{
          "managed_by" => "catalogue",
          "locked_keys" => ["kind", "default_value_slug"],
          "catalogue" => %{"kind" => "multi", "default_value_slug" => "oak"}
        }
      },
      overrides
    )
  end

  defp data_record(overrides \\ %{}) do
    Map.merge(%{slug: "oak", title: "Oak", status: "published"}, overrides)
  end

  defp multilang_record(overrides \\ %{}) do
    data_record(
      Map.merge(
        %{
          data: %{
            "_primary_language" => "en",
            "en" => %{"_title" => "Oak", "_slug" => "oak"},
            "et" => %{"_title" => "Tamm", "_slug" => "tamm"}
          }
        },
        overrides
      )
    )
  end

  @doc false
  def allow_delete(_entity), do: :ok

  describe "register_delete_guard/2" do
    test "concurrent registrations for different owners all land" do
      # Owners register from their own boot tasks at the same moment (the
      # catalogue starts two); a shared map's read-modify-write lost one.
      run = System.unique_integer([:positive])
      owners = for i <- 1..40, do: "concurrent-owner-#{run}-#{i}"

      on_exit(fn ->
        Enum.each(owners, &:persistent_term.erase({Managed, :delete_guard, &1}))
      end)

      parent = self()

      tasks =
        Enum.map(owners, fn owner ->
          Task.async(fn ->
            # Every task is parked here until all forty exist, so the
            # registrations overlap instead of running one after another.
            send(parent, {:ready, self()})

            receive do
              :go -> Managed.register_delete_guard(owner, &__MODULE__.allow_delete/1)
            end
          end)
        end)

      for _ <- tasks, do: assert_receive({:ready, _}, 5_000)
      Enum.each(tasks, &send(&1.pid, :go))
      # register_delete_guard/2 returns :persistent_term.put/2's result as is.
      assert Enum.uniq(Task.await_many(tasks, 10_000)) == [:ok]

      refused =
        Enum.reject(owners, fn owner ->
          entity = managed_entity(%{settings: %{"managed_by" => owner}})
          Managed.validate_delete(entity, on_behalf_of: owner) == :ok
        end)

      assert refused == []
    end
  end

  describe "validate_mutation/3" do
    test "unmanaged entities are untouched" do
      assert :ok = Managed.validate_mutation(%{settings: %{}}, %{"name" => "x"})
    end

    test "generic writes cannot rename identity or status" do
      e = managed_entity()
      assert {:error, :managed_blueprint} = Managed.validate_mutation(e, %{"name" => "renamed"})

      assert {:error, :managed_blueprint} =
               Managed.validate_mutation(e, %{"status" => "archived"})
    end

    test "generic writes cannot change locked owner-settings keys" do
      e = managed_entity()

      attrs = %{
        "settings" => %{
          "managed_by" => "catalogue",
          "locked_keys" => ["kind", "default_value_slug"],
          "catalogue" => %{"kind" => "fixed", "default_value_slug" => "oak"}
        }
      }

      assert {:error, :locked_key} = Managed.validate_mutation(e, attrs)
    end

    test "adding new fields/settings stays allowed (the extras contract)" do
      e = managed_entity()

      attrs = %{
        "fields_definition" => [%{"type" => "number", "key" => "price_per_liter"}],
        "settings" =>
          e.settings
          |> put_in(["catalogue", "vendor"], "ikea")
      }

      assert :ok = Managed.validate_mutation(e, attrs)
    end

    test "the owner passes unconditionally via on_behalf_of" do
      e = managed_entity()

      assert :ok =
               Managed.validate_mutation(e, %{"name" => "renamed"}, on_behalf_of: "catalogue")
    end

    test "generic writes cannot rewrite or drop the marker keys themselves" do
      e = managed_entity()

      # Dropping managed_by would un-manage the blueprint entirely.
      assert {:error, :managed_blueprint} =
               Managed.validate_mutation(e, %{
                 "settings" => Map.delete(e.settings, "managed_by")
               })

      # Emptying locked_keys would unlock every contract key.
      assert {:error, :managed_blueprint} =
               Managed.validate_mutation(e, %{
                 "settings" => Map.put(e.settings, "locked_keys", [])
               })

      # The owner may still restructure its own contract.
      assert :ok =
               Managed.validate_mutation(
                 e,
                 %{"settings" => Map.put(e.settings, "locked_keys", ["kind"])},
                 on_behalf_of: "catalogue"
               )
    end
  end

  describe "validate_data_mutation/4" do
    test "unmanaged owning entity is untouched, slug change and all" do
      assert :ok =
               Managed.validate_data_mutation(%{settings: %{}}, data_record(), %{
                 "slug" => "renamed"
               })
    end

    test "a nil owning entity (dangling entity_uuid) is treated as unmanaged" do
      assert :ok = Managed.validate_data_mutation(nil, data_record(), %{"slug" => "renamed"})
    end

    test "generic writes cannot rename a managed value record's slug" do
      owning = managed_entity()

      assert {:error, :locked_key} =
               Managed.validate_data_mutation(owning, data_record(), %{"slug" => "renamed"})

      assert {:error, :locked_key} =
               Managed.validate_data_mutation(owning, data_record(), %{slug: "renamed"})
    end

    test "resubmitting the SAME slug is not a rename — the disabled field's hidden mirror" do
      owning = managed_entity()

      assert :ok = Managed.validate_data_mutation(owning, data_record(), %{"slug" => "oak"})
    end

    test "every other field on a managed value record stays unguarded" do
      owning = managed_entity()
      record = data_record()

      assert :ok =
               Managed.validate_data_mutation(owning, record, %{
                 "title" => "Renamed",
                 "status" => "archived",
                 "data" => %{"color" => "brown"}
               })
    end

    test "the owner passes unconditionally via on_behalf_of, even renaming the slug" do
      owning = managed_entity()

      assert :ok =
               Managed.validate_data_mutation(owning, data_record(), %{"slug" => "renamed"},
                 on_behalf_of: "catalogue"
               )
    end

    # MAJOR-1 (2026-09-11 review): re-pointing a value record at another
    # blueprint detaches it from the owner's set exactly as thoroughly as
    # renaming its slug — `list_values_for/1` filters by `entity_uuid`,
    # not by `slug`. Confirmed before this fix:
    # `EntityData.validate_managed_slug/3` only ever consulted
    # `renames_data_slug?/2`, so a bare `entity_uuid` change walked
    # straight past the guard and returned `:ok`.
    test "generic writes cannot re-point a managed value record at another blueprint" do
      owning = managed_entity()
      record = data_record(%{entity_uuid: "entity-a"})

      assert {:error, :locked_key} =
               Managed.validate_data_mutation(owning, record, %{"entity_uuid" => "entity-b"})

      assert {:error, :locked_key} =
               Managed.validate_data_mutation(owning, record, %{entity_uuid: "entity-b"})
    end

    test "resubmitting the SAME entity_uuid is not a move" do
      owning = managed_entity()
      record = data_record(%{entity_uuid: "entity-a"})

      assert :ok = Managed.validate_data_mutation(owning, record, %{"entity_uuid" => "entity-a"})
    end

    test "the owner passes unconditionally via on_behalf_of, even re-pointing entity_uuid" do
      owning = managed_entity()
      record = data_record(%{entity_uuid: "entity-a"})

      assert :ok =
               Managed.validate_data_mutation(owning, record, %{"entity_uuid" => "entity-b"},
                 on_behalf_of: "catalogue"
               )
    end

    test "a nil new slug (key absent from attrs) is not a rename" do
      owning = managed_entity()

      assert :ok = Managed.validate_data_mutation(owning, data_record(), %{"title" => "Oak"})
    end

    # MAJOR (2026-09-11 review): the old check was `is_binary(new_slug) and
    # new_slug != data_record.slug` — an explicit `slug: nil` in `attrs`
    # is not a binary, so it read as "untouched" and walked straight past
    # the guard, silently erasing an existing slug.
    #
    # This hardens `renames_data_slug?/2`'s contract for ANY caller, not a
    # fix for a known exploit: no caller in this codebase reaches
    # `validate_data_mutation/4` with a present-but-nil slug today.
    # `Mirror.Importer`'s `:overwrite` strategy looks like a candidate but
    # isn't — `import_data_record/3` (mirror/importer.ex) sends a JSON
    # record with no `"slug"` key straight to `create_data_from_import`,
    # never to `handle_data_conflict/3`, because a nil/`""` slug can never
    # be matched to an existing record in the first place. See the `@doc`
    # on `renames_data_slug?/2` for the same rationale at the function's
    # own boundary.
    test "an explicit nil slug on a record that HAS one is a rename, not a no-op" do
      owning = managed_entity()

      assert {:error, :locked_key} =
               Managed.validate_data_mutation(owning, data_record(), %{"slug" => nil})

      assert {:error, :locked_key} =
               Managed.validate_data_mutation(owning, data_record(), %{slug: nil})
    end

    # CRITICAL (2026-09-11 review): a record can legitimately have
    # `slug: nil` (created without one). The disabled field's hidden
    # mirror then posts back `""` (there is no slug to render into the
    # input) — the old check read that as `is_binary("") and "" != nil`,
    # i.e. `true`, refusing EVERY subsequent save (even a title-only
    # edit) with `:locked_key` forever. `""` and `nil` are now the same
    # "no slug" on both sides of the compare, matching what Ecto's own
    # `cast/4` would do with `""`.
    test "resubmitting \"\" against an already-nil slug is not a rename" do
      owning = managed_entity()
      record = data_record(%{slug: nil})

      assert :ok = Managed.validate_data_mutation(owning, record, %{"slug" => ""})
      assert :ok = Managed.validate_data_mutation(owning, record, %{slug: ""})
    end

    test "but submitting \"\" against a record that HAS a slug is still a rename" do
      owning = managed_entity()

      assert {:error, :locked_key} =
               Managed.validate_data_mutation(owning, data_record(), %{"slug" => ""})
    end
  end

  describe "moves_data_record?/2" do
    test "an entity_uuid identical to the record's own is not a move" do
      record = data_record(%{entity_uuid: "entity-a"})

      refute Managed.moves_data_record?(record, %{"entity_uuid" => "entity-a"})
      refute Managed.moves_data_record?(record, %{entity_uuid: "entity-a"})
    end

    test "a different entity_uuid is a move" do
      record = data_record(%{entity_uuid: "entity-a"})

      assert Managed.moves_data_record?(record, %{"entity_uuid" => "entity-b"})
      assert Managed.moves_data_record?(record, %{entity_uuid: "entity-b"})
    end

    test "entity_uuid absent from attrs is not a move" do
      record = data_record(%{entity_uuid: "entity-a"})

      refute Managed.moves_data_record?(record, %{"title" => "Oak"})
    end
  end

  describe "renames_translated_slug?/2" do
    test "a secondary language's unchanged _slug is not a rename" do
      record = multilang_record()

      refute Managed.renames_translated_slug?(record, %{
               "data" => %{"et" => %{"_title" => "Tamm", "_slug" => "tamm"}}
             })
    end

    test "a secondary language's changed _slug IS a rename" do
      record = multilang_record()

      assert Managed.renames_translated_slug?(record, %{
               "data" => %{"et" => %{"_title" => "Tamm", "_slug" => "forged-tamm"}}
             })
    end

    test "a language present without a _slug key is not a rename — overrides only" do
      record = multilang_record()

      refute Managed.renames_translated_slug?(record, %{
               "data" => %{"et" => %{"_title" => "Tamm (renamed)"}}
             })
    end

    test "a brand-new language's _slug is a rename against the implicit nil" do
      record = multilang_record()

      assert Managed.renames_translated_slug?(record, %{
               "data" => %{"fr" => %{"_title" => "Chêne", "_slug" => "chene"}}
             })
    end

    test "attrs without a data key is not a rename" do
      record = multilang_record()

      refute Managed.renames_translated_slug?(record, %{"title" => "Oak"})
    end

    test "a record with no prior data treats any _slug as a rename" do
      record = data_record()

      assert Managed.renames_translated_slug?(record, %{
               "data" => %{"et" => %{"_slug" => "tamm"}}
             })
    end

    # The multilang data form seeds `data[primary]["_slug"]` from the slug
    # column and injects it on every save. A row stored without its own
    # primary `_slug` must not read that injected copy as a rename, or no
    # save from the form ever goes through.
    test "an injected primary _slug equal to the slug column is not a rename" do
      record =
        multilang_record(%{data: %{"_primary_language" => "en", "en" => %{"_title" => "Oak"}}})

      refute Managed.renames_translated_slug?(record, %{
               "data" => %{
                 "_primary_language" => "en",
                 "en" => %{"_title" => "Oak", "_slug" => "oak"}
               }
             })
    end

    test "an injected primary _slug that differs from the slug column IS a rename" do
      record =
        multilang_record(%{data: %{"_primary_language" => "en", "en" => %{"_title" => "Oak"}}})

      assert Managed.renames_translated_slug?(record, %{
               "data" => %{
                 "_primary_language" => "en",
                 "en" => %{"_title" => "Oak", "_slug" => "forged-oak"}
               }
             })
    end

    test "the slug-column fallback applies to the primary language only" do
      record =
        multilang_record(%{data: %{"_primary_language" => "en", "en" => %{"_title" => "Oak"}}})

      assert Managed.renames_translated_slug?(record, %{
               "data" => %{"et" => %{"_title" => "Tamm", "_slug" => "oak"}}
             })
    end
  end

  describe "validate_data_mutation/4 — translated slug" do
    test "generic writes cannot rename a secondary language's slug override" do
      owning = managed_entity()
      record = multilang_record()

      assert {:error, :locked_key} =
               Managed.validate_data_mutation(owning, record, %{
                 "data" => %{"et" => %{"_slug" => "forged-tamm"}}
               })
    end

    test "the owner passes unconditionally via on_behalf_of, even renaming a translated slug" do
      owning = managed_entity()
      record = multilang_record()

      assert :ok =
               Managed.validate_data_mutation(
                 owning,
                 record,
                 %{"data" => %{"et" => %{"_slug" => "forged-tamm"}}},
                 on_behalf_of: "catalogue"
               )
    end
  end

  describe "data_mutation_needs_owner?/2" do
    test "false for a save that touches none of the guarded fields" do
      record = multilang_record(%{entity_uuid: "entity-a"})

      refute Managed.data_mutation_needs_owner?(record, %{"title" => "Renamed"})
    end

    test "true when the top-level slug changes" do
      record = data_record()

      assert Managed.data_mutation_needs_owner?(record, %{"slug" => "renamed"})
    end

    test "true when a translated slug override changes" do
      record = multilang_record()

      assert Managed.data_mutation_needs_owner?(record, %{
               "data" => %{"et" => %{"_slug" => "forged-tamm"}}
             })
    end

    test "true when entity_uuid changes" do
      record = data_record(%{entity_uuid: "entity-a"})

      assert Managed.data_mutation_needs_owner?(record, %{"entity_uuid" => "entity-b"})
    end
  end

  describe "validate_data_mutation/4 — owning_entity mismatch (MINOR-4)" do
    # MINOR-4 (2026-09-11 review): nothing checked that `owning_entity`
    # actually belongs to `data_record`. Confirmed before this fix: an
    # unrelated UNMANAGED blueprint (any uuid other than the record's
    # own) short-circuited the very first `cond` clause (`not
    # managed?(owning_entity)`) and returned `:ok` for a rename that
    # SHOULD have been evaluated against the record's real (managed)
    # owner.
    test "an unrelated, unmanaged owning_entity cannot be used to slip a rename past the real owner" do
      record = data_record(%{entity_uuid: "entity-a"})
      wrong_owner = %{uuid: "entity-b", settings: %{}}

      assert {:error, :locked_key} =
               Managed.validate_data_mutation(wrong_owner, record, %{"slug" => "renamed"})
    end

    test "an unrelated MANAGED owning_entity is refused the same way, not evaluated as if it were real" do
      record = data_record(%{entity_uuid: "entity-a"})
      wrong_owner = managed_entity(%{uuid: "entity-b"})

      assert {:error, :locked_key} =
               Managed.validate_data_mutation(wrong_owner, record, %{"title" => "harmless"})
    end

    test "a matching entity_uuid is not a mismatch — the ordinary call shape" do
      owning = managed_entity(%{uuid: "entity-a"})
      record = data_record(%{entity_uuid: "entity-a"})

      assert {:error, :locked_key} =
               Managed.validate_data_mutation(owning, record, %{"slug" => "renamed"})

      assert :ok = Managed.validate_data_mutation(owning, record, %{"title" => "Renamed"})
    end

    test "fixtures with no uuid set at all (most tests in this file) are not a mismatch" do
      owning = managed_entity()
      record = data_record()

      assert {:error, :locked_key} =
               Managed.validate_data_mutation(owning, record, %{"slug" => "renamed"})
    end
  end

  describe "validate_creation/2" do
    test "generic creates cannot claim a managed_by owner" do
      attrs = %{settings: %{"managed_by" => "catalogue"}, name: "catalogue_set_forged"}

      assert {:error, :managed_blueprint} = Managed.validate_creation(attrs)
      assert :ok = Managed.validate_creation(attrs, on_behalf_of: "catalogue")
      assert :ok = Managed.validate_creation(%{name: "plain", settings: %{}})
      assert :ok = Managed.validate_creation(%{name: "no_settings"})
    end

    test "atom-keyed settings cannot slip a claim past the guard" do
      # Ecto's :map stores atom-keyed maps as given and JSONB-encodes
      # them to string keys — a string-only lookup fails OPEN here
      # (panel finding, 2026-08-19 review).
      attrs = %{settings: %{managed_by: "catalogue"}, name: "catalogue_set_forged"}

      assert {:error, :managed_blueprint} = Managed.validate_creation(attrs)
      assert :ok = Managed.validate_creation(attrs, on_behalf_of: "catalogue")
    end
  end

  describe "marker acquisition via update (create-then-update masquerade)" do
    test "an unmanaged blueprint cannot acquire managed_by generically" do
      unmanaged = %{name: "plain", status: "published", settings: %{}}
      claim = %{settings: %{"managed_by" => "catalogue", "locked_keys" => ["kind"]}}

      assert {:error, :managed_blueprint} = Managed.validate_mutation(unmanaged, claim)
      # Atom-keyed claim is caught the same way.
      assert {:error, :managed_blueprint} =
               Managed.validate_mutation(unmanaged, %{settings: %{managed_by: "catalogue"}})

      # The claimed owner itself may stamp its own markers.
      assert :ok = Managed.validate_mutation(unmanaged, claim, on_behalf_of: "catalogue")

      # Settings writes without a claim stay untouched.
      assert :ok = Managed.validate_mutation(unmanaged, %{settings: %{"sort_mode" => "manual"}})
    end
  end

  describe "validate_delete/2" do
    # Guards outlive the test process; without erasing them, the "fails
    # closed without a registered guard" pin only holds in a fresh VM (a
    # --repeat-until-failure run fails it on the second pass).
    setup do
      on_exit(fn ->
        for owner <- ["managed_test_owner", "crashy_owner"],
            do: :persistent_term.erase({Managed, :delete_guard, owner})
      end)
    end

    test "generic deletes of managed blueprints are refused" do
      assert {:error, :managed_blueprint} = Managed.validate_delete(managed_entity())
    end

    test "owner deletes fail closed without a registered guard, pass with approval" do
      e = managed_entity(%{settings: %{"managed_by" => "managed_test_owner"}})

      assert {:error, :no_delete_guard} =
               Managed.validate_delete(e, on_behalf_of: "managed_test_owner")

      Managed.register_delete_guard("managed_test_owner", fn _e -> :ok end)
      assert :ok = Managed.validate_delete(e, on_behalf_of: "managed_test_owner")

      Managed.register_delete_guard("managed_test_owner", fn _e -> {:error, :set_in_use} end)

      assert {:error, :set_in_use} =
               Managed.validate_delete(e, on_behalf_of: "managed_test_owner")
    end

    test "a crashing or misbehaving guard fails closed, never propagates" do
      e = managed_entity(%{settings: %{"managed_by" => "crashy_owner"}})

      Managed.register_delete_guard("crashy_owner", fn _e -> raise "stale fun" end)

      assert {:error, :delete_guard_error} =
               Managed.validate_delete(e, on_behalf_of: "crashy_owner")

      Managed.register_delete_guard("crashy_owner", fn _e -> :weird end)

      assert {:error, {:invalid_guard_result, :weird}} =
               Managed.validate_delete(e, on_behalf_of: "crashy_owner")

      # An EXIT (e.g. the guard's DB connection owner died) fails
      # closed the same way a raise does.
      Managed.register_delete_guard("crashy_owner", fn _e -> exit(:connection_died) end)

      assert {:error, :delete_guard_error} =
               Managed.validate_delete(e, on_behalf_of: "crashy_owner")
    end
  end

  describe "DB integration" do
    test "update/delete paths enforce the guard; listing and cap exclude managed" do
      actor_uuid = Ecto.UUID.generate()

      managed_attrs = %{
        name: "catalogue_set_test_colors",
        display_name: "Test colors",
        display_name_plural: "Test colors",
        status: "published",
        fields_definition: [],
        created_by_uuid: actor_uuid,
        settings: %{
          "managed_by" => "catalogue",
          "locked_keys" => ["kind"],
          "catalogue" => %{"kind" => "multi"}
        }
      }

      # Creation guard live on the real create path: generic callers
      # cannot claim an owner; the owner provisions via on_behalf_of.
      assert {:error, :managed_blueprint} = PhoenixKitEntities.create_entity(managed_attrs)
      {:ok, managed} = PhoenixKitEntities.create_entity(managed_attrs, on_behalf_of: "catalogue")

      {:ok, _plain} =
        PhoenixKitEntities.create_entity(%{
          name: "plain_entity",
          display_name: "Plain",
          display_name_plural: "Plains",
          status: "published",
          fields_definition: [],
          created_by_uuid: actor_uuid
        })

      # Write guard live on the real update path.
      assert {:error, :managed_blueprint} =
               PhoenixKitEntities.update_entity(managed, %{"name" => "sneaky"})

      assert {:ok, _} =
               PhoenixKitEntities.update_entity(managed, %{"name" => "renamed_by_owner"},
                 on_behalf_of: "catalogue"
               )

      # Delete guard live.
      assert {:error, :managed_blueprint} = PhoenixKitEntities.delete_entity(managed)

      # Listing exclusion.
      names = PhoenixKitEntities.list_entities(include_managed: false) |> Enum.map(& &1.name)
      assert "plain_entity" in names
      refute Enum.any?(names, &String.starts_with?(&1, "catalogue_set_"))

      # Cap exemption: only the plain entity counts for its creator.
      assert PhoenixKitEntities.count_user_entities(actor_uuid) == 1
    end
  end

  describe "DB integration — data record entity_uuid guard" do
    # MAJOR-1 (2026-09-11 review), reproduced end-to-end through the real
    # `EntityData.update/3` write path, not just `Managed`'s pure functions.
    test "generic writes cannot re-point a managed value record at another blueprint" do
      actor_uuid = Ecto.UUID.generate()

      {:ok, managed} =
        PhoenixKitEntities.create_entity(
          %{
            name: "catalogue_set_test_woods",
            display_name: "Test woods",
            display_name_plural: "Test woods",
            status: "published",
            fields_definition: [],
            created_by_uuid: actor_uuid,
            settings: %{
              "managed_by" => "catalogue",
              "locked_keys" => ["kind"],
              "catalogue" => %{"kind" => "multi"}
            }
          },
          on_behalf_of: "catalogue"
        )

      {:ok, plain} =
        PhoenixKitEntities.create_entity(%{
          name: "plain_target",
          display_name: "Plain target",
          display_name_plural: "Plain targets",
          status: "published",
          fields_definition: [],
          created_by_uuid: actor_uuid
        })

      {:ok, record} =
        EntityData.create(%{
          entity_uuid: managed.uuid,
          title: "Oak",
          slug: "oak",
          status: "published",
          data: %{},
          created_by_uuid: actor_uuid
        })

      # BEFORE this fix: {:ok, updated} — the record silently left
      # `managed`'s set while its slug ("oak") stayed behind as a ghost
      # in the owner's `selected_value_slugs`.
      assert {:error, :locked_key} = EntityData.update(record, %{"entity_uuid" => plain.uuid})
      assert EntityData.get(record.uuid).entity_uuid == managed.uuid

      # Renaming the slug on the same record was already refused before
      # this fix — kept here so both guarded fields are exercised
      # end-to-end in one DB-backed test.
      assert {:error, :locked_key} = EntityData.update(record, %{"slug" => "not-oak"})

      # The owner may still re-point its own record.
      assert {:ok, moved} =
               EntityData.update(record, %{"entity_uuid" => plain.uuid},
                 on_behalf_of: "catalogue"
               )

      assert moved.entity_uuid == plain.uuid
    end
  end
end
