defmodule PhoenixKitEntities.EntityDataChangesetTest do
  use PhoenixKitEntities.DataCase, async: true

  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData

  setup do
    actor_uuid = Ecto.UUID.generate()

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "data_cs_test",
          display_name: "Data CS Test",
          display_name_plural: "Data CS Tests",
          fields_definition: [
            %{"type" => "text", "key" => "name", "label" => "Name"}
          ],
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, entity: entity, actor_uuid: actor_uuid}
  end

  defp valid_attrs(ctx) do
    %{
      entity_uuid: ctx.entity.uuid,
      title: "Test Record",
      created_by_uuid: ctx.actor_uuid
    }
  end

  defp changeset(ctx, attrs \\ %{}) do
    EntityData.changeset(%EntityData{}, Map.merge(valid_attrs(ctx), attrs))
  end

  describe "required fields" do
    test "valid with required fields", ctx do
      cs = changeset(ctx)
      refute errors_on(cs)[:title]
      refute errors_on(cs)[:entity_uuid]
    end

    test "invalid without title", ctx do
      cs = changeset(ctx, %{title: nil})
      assert errors_on(cs)[:title]
    end

    test "invalid without entity_uuid", ctx do
      cs = changeset(ctx, %{entity_uuid: nil})
      assert errors_on(cs)[:entity_uuid]
    end
  end

  describe "title validation" do
    test "valid title", ctx do
      cs = changeset(ctx, %{title: "My Record"})
      refute errors_on(cs)[:title]
    end

    test "invalid - empty string", ctx do
      cs = changeset(ctx, %{title: ""})
      assert errors_on(cs)[:title]
    end

    test "invalid - too long (256 chars)", ctx do
      cs = changeset(ctx, %{title: String.duplicate("x", 256)})
      assert errors_on(cs)[:title]
    end

    test "valid - max length (255 chars)", ctx do
      cs = changeset(ctx, %{title: String.duplicate("x", 255)})
      refute errors_on(cs)[:title]
    end
  end

  describe "slug validation" do
    test "valid slug", ctx do
      cs = changeset(ctx, %{slug: "my-record"})
      refute errors_on(cs)[:slug]
    end

    test "valid slug with numbers", ctx do
      cs = changeset(ctx, %{slug: "record-123"})
      refute errors_on(cs)[:slug]
    end

    test "nil slug is valid (optional)", ctx do
      cs = changeset(ctx, %{slug: nil})
      refute errors_on(cs)[:slug]
    end

    test "empty slug is valid", ctx do
      cs = changeset(ctx, %{slug: ""})
      refute errors_on(cs)[:slug]
    end

    test "invalid - uppercase letters", ctx do
      cs = changeset(ctx, %{slug: "My-Record"})
      assert errors_on(cs)[:slug]
    end

    test "invalid - spaces", ctx do
      cs = changeset(ctx, %{slug: "my record"})
      assert errors_on(cs)[:slug]
    end

    test "invalid - underscores", ctx do
      cs = changeset(ctx, %{slug: "my_record"})
      assert errors_on(cs)[:slug]
    end

    test "invalid - double hyphens", ctx do
      cs = changeset(ctx, %{slug: "my--record"})
      assert errors_on(cs)[:slug]
    end

    test "invalid - starts with hyphen", ctx do
      cs = changeset(ctx, %{slug: "-record"})
      assert errors_on(cs)[:slug]
    end

    test "invalid - ends with hyphen", ctx do
      cs = changeset(ctx, %{slug: "record-"})
      assert errors_on(cs)[:slug]
    end

    test "invalid - too long (256 chars)", ctx do
      cs = changeset(ctx, %{slug: String.duplicate("a", 256)})
      assert errors_on(cs)[:slug]
    end
  end

  describe "status validation" do
    test "valid - draft", ctx do
      cs = changeset(ctx, %{status: "draft"})
      refute errors_on(cs)[:status]
    end

    test "valid - published", ctx do
      cs = changeset(ctx, %{status: "published"})
      refute errors_on(cs)[:status]
    end

    test "valid - archived", ctx do
      cs = changeset(ctx, %{status: "archived"})
      refute errors_on(cs)[:status]
    end

    test "invalid status", ctx do
      cs = changeset(ctx, %{status: "deleted"})
      assert errors_on(cs)[:status]
    end
  end

  describe "data and metadata" do
    test "accepts map data", ctx do
      cs = changeset(ctx, %{data: %{"name" => "Test", "price" => 10}})
      assert Ecto.Changeset.get_field(cs, :data) == %{"name" => "Test", "price" => 10}
    end

    test "accepts map metadata", ctx do
      cs = changeset(ctx, %{metadata: %{"tags" => ["featured"]}})
      assert Ecto.Changeset.get_field(cs, :metadata) == %{"tags" => ["featured"]}
    end

    test "accepts nil metadata", ctx do
      cs = changeset(ctx, %{metadata: nil})
      refute errors_on(cs)[:metadata]
    end
  end

  describe "number/decimal field normalization (matches the admin FormBuilder path)" do
    # The public form endpoint builds `EntityData.changeset/2` directly,
    # never through `FormBuilder.validate_type/2` — so without this, a
    # "number"/"decimal" value it submits would land in storage as raw
    # typed text while the SAME input typed into the admin form
    # (`FormBuilder.validate_data/2`) is coerced to a float/`Decimal`
    # first. Two representations for the same field type would break any
    # downstream arithmetic, filter, or sort on it.
    setup do
      actor_uuid = Ecto.UUID.generate()

      {:ok, entity} =
        Entities.create_entity(
          %{
            name: "data_cs_numeric_test",
            display_name: "Data CS Numeric Test",
            display_name_plural: "Data CS Numeric Tests",
            fields_definition: [
              %{"type" => "number", "key" => "qty", "label" => "Qty"},
              %{"type" => "decimal", "key" => "price", "label" => "Price"}
            ],
            created_by_uuid: actor_uuid
          },
          actor_uuid: actor_uuid
        )

      {:ok, entity: entity, actor_uuid: actor_uuid}
    end

    test "a comma-decimal 'number' value is stored exactly as FormBuilder casts it", ctx do
      cs = changeset(ctx, %{data: %{"qty" => "2,5"}})

      assert {:ok, %{"qty" => expected}} =
               PhoenixKitEntities.FormBuilder.validate_data(ctx.entity, %{"qty" => "2,5"})

      assert Ecto.Changeset.get_field(cs, :data) == %{"qty" => expected}
      assert is_float(expected)
    end

    test "a comma-decimal 'decimal' value is stored exactly as FormBuilder casts it", ctx do
      cs = changeset(ctx, %{data: %{"price" => "5,10"}})

      assert {:ok, %{"price" => expected}} =
               PhoenixKitEntities.FormBuilder.validate_data(ctx.entity, %{"price" => "5,10"})

      assert Ecto.Changeset.get_field(cs, :data) == %{"price" => expected}
      assert %Decimal{} = expected
    end

    test "invalid text is left untouched and still rejected", ctx do
      cs = changeset(ctx, %{data: %{"qty" => "not-a-number"}})

      assert Ecto.Changeset.get_field(cs, :data) == %{"qty" => "not-a-number"}
      assert errors_on(cs)[:data]
    end
  end

  describe "decimal field bounds (mirrors validate_number_field/3)" do
    # `validate_decimal_field/3` used to check shape only
    # (`decimal_shaped?/1`, since removed) and never looked at
    # `min`/`max`. An out-of-bounds value fails to cast in
    # `normalize_numeric_data/1` (see `FormBuilder.apply_decimal_bounds/2`)
    # and is therefore left in its raw, still-shape-valid form — with no
    # bounds check downstream, this changeset (the only gate a public
    # submission passes) accepted it anyway.
    setup do
      actor_uuid = Ecto.UUID.generate()

      {:ok, entity} =
        Entities.create_entity(
          %{
            name: "data_cs_decimal_bounds_test",
            display_name: "Data CS Decimal Bounds Test",
            display_name_plural: "Data CS Decimal Bounds Tests",
            fields_definition: [
              %{
                "type" => "decimal",
                "key" => "price",
                "label" => "Price",
                "min" => "0",
                "max" => "10"
              }
            ],
            created_by_uuid: actor_uuid
          },
          actor_uuid: actor_uuid
        )

      {:ok, entity: entity, actor_uuid: actor_uuid}
    end

    test "rejects an out-of-bounds value", ctx do
      cs = changeset(ctx, %{data: %{"price" => "999"}})
      refute cs.valid?
      assert errors_on(cs)[:data]
    end

    test "rejects an out-of-bounds comma-decimal value", ctx do
      cs = changeset(ctx, %{data: %{"price" => "-1,00"}})
      refute cs.valid?
      assert errors_on(cs)[:data]
    end

    test "accepts an in-bounds comma-decimal value, cast the same as FormBuilder", ctx do
      cs = changeset(ctx, %{data: %{"price" => "5,10"}})

      assert {:ok, %{"price" => expected}} =
               PhoenixKitEntities.FormBuilder.validate_data(ctx.entity, %{"price" => "5,10"})

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :data) == %{"price" => expected}
      assert %Decimal{} = expected
    end
  end

  describe "malformed numeric bounds in a field definition" do
    # `Number.parse_decimal/2` raises on a `:min`/`:max` it cannot read.
    # Bounds are definition DATA (mirror import, API), so `""`, a typo or
    # "NaN" must be ignored the way `FormBuilder` ignores them — not turn
    # every save of the record into an `ArgumentError` / `Decimal.Error`.
    setup do
      actor_uuid = Ecto.UUID.generate()

      {:ok, entity} =
        Entities.create_entity(
          %{
            name: "data_cs_bad_bounds_test",
            display_name: "Data CS Bad Bounds Test",
            display_name_plural: "Data CS Bad Bounds Tests",
            fields_definition: [
              %{
                "type" => "number",
                "key" => "qty",
                "label" => "Qty",
                "min" => "",
                "max" => "abc"
              },
              %{
                "type" => "decimal",
                "key" => "price",
                "label" => "Price",
                "min" => "NaN",
                "max" => %{"x" => 1}
              }
            ],
            created_by_uuid: actor_uuid
          },
          actor_uuid: actor_uuid
        )

      {:ok, entity: entity, actor_uuid: actor_uuid}
    end

    test "unreadable bounds are ignored, not raised on", ctx do
      cs = changeset(ctx, %{data: %{"qty" => "2,5", "price" => "-5,10"}})

      assert cs.valid?
      assert %{"qty" => 2.5, "price" => %Decimal{} = price} = Ecto.Changeset.get_field(cs, :data)
      assert Decimal.equal?(price, Decimal.new("-5.10"))
    end

    test "invalid values are still rejected", ctx do
      cs = changeset(ctx, %{data: %{"qty" => "x", "price" => "y"}})
      refute cs.valid?
    end
  end

  describe "position" do
    test "accepts integer position", ctx do
      cs = changeset(ctx, %{position: 5})
      assert Ecto.Changeset.get_field(cs, :position) == 5
    end

    test "accepts nil position", ctx do
      cs = changeset(ctx, %{position: nil})
      refute errors_on(cs)[:position]
    end
  end

  describe "heading fields" do
    setup ctx do
      {:ok, heading_entity} =
        Entities.create_entity(
          %{
            name: "data_cs_heading_test",
            display_name: "Data CS Heading Test",
            display_name_plural: "Data CS Heading Tests",
            fields_definition: [
              %{"type" => "heading", "key" => "sec_ahi", "label" => "Ahi", "required" => true},
              %{"type" => "text", "key" => "name", "label" => "Name"}
            ],
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, heading_entity: heading_entity}
    end

    test "required=true on a heading never blocks saving the record", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.heading_entity.uuid,
          title: "Heading Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"name" => "value"}
        })

      refute errors_on(cs)[:data]
    end
  end

  describe "select field with allow_other" do
    setup ctx do
      {:ok, select_entity} =
        Entities.create_entity(
          %{
            name: "data_cs_select_other_test",
            display_name: "Data CS Select Other Test",
            display_name_plural: "Data CS Select Other Tests",
            fields_definition: [
              %{
                "type" => "select",
                "key" => "color",
                "label" => "Color",
                "options" => ["Red", "Blue"],
                "allow_other" => true
              }
            ],
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, select_entity: select_entity}
    end

    test "a value outside options is accepted when allow_other is true", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.select_entity.uuid,
          title: "Select Other Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"color" => "Crimson"}
        })

      refute errors_on(cs)[:data]
    end

    test "a known option is still accepted", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.select_entity.uuid,
          title: "Select Other Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"color" => "Red"}
        })

      refute errors_on(cs)[:data]
    end

    test "without allow_other, a value outside options is still rejected", ctx do
      {:ok, entity} =
        Entities.create_entity(
          %{
            name: "data_cs_select_strict_test",
            display_name: "Data CS Select Strict Test",
            display_name_plural: "Data CS Select Strict Tests",
            fields_definition: [
              %{
                "type" => "select",
                "key" => "color",
                "label" => "Color",
                "options" => ["Red", "Blue"]
              }
            ],
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: entity.uuid,
          title: "Select Strict Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"color" => "Crimson"}
        })

      assert errors_on(cs)[:data]
    end

    test "the __other__ sentinel itself is always rejected, even with allow_other", ctx do
      # A UI marker, never a legitimate stored value — reaching the
      # changeset means `FormBuilder.merge_other_params/2` failed to
      # resolve it upstream, so this must fail the same as any other
      # out-of-options value.
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.select_entity.uuid,
          title: "Select Other Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"color" => "__other__"}
        })

      assert errors_on(cs)[:data]
    end

    test "a map value is rejected even with allow_other (M2 follow-up)", ctx do
      # `allow_other`'s whole premise is a free-text custom answer, i.e. a
      # string — this branch used to accept ANY value once it wasn't a
      # recognized option, map values included.
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.select_entity.uuid,
          title: "Select Other Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"color" => %{"evil" => "map"}}
        })

      assert errors_on(cs)[:data]
    end
  end

  describe "radio field validation" do
    setup ctx do
      {:ok, radio_entity} =
        Entities.create_entity(
          %{
            name: "data_cs_radio_test",
            display_name: "Data CS Radio Test",
            display_name_plural: "Data CS Radio Tests",
            fields_definition: [
              %{
                "type" => "radio",
                "key" => "priority",
                "label" => "Priority",
                "options" => ["Low", "High"],
                "allow_other" => true
              }
            ],
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, radio_entity: radio_entity}
    end

    test "a known option is accepted", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.radio_entity.uuid,
          title: "Radio Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"priority" => "Low"}
        })

      refute errors_on(cs)[:data]
    end

    test "a value outside options is accepted when allow_other is true", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.radio_entity.uuid,
          title: "Radio Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"priority" => "Medium"}
        })

      refute errors_on(cs)[:data]
    end

    test "the __other__ sentinel is rejected even with allow_other", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.radio_entity.uuid,
          title: "Radio Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"priority" => "__other__"}
        })

      assert errors_on(cs)[:data]
    end

    test "a map value is rejected even with allow_other (M2 follow-up)", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.radio_entity.uuid,
          title: "Radio Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"priority" => %{"evil" => "map"}}
        })

      assert errors_on(cs)[:data]
    end

    test "without allow_other, a value outside options is rejected", ctx do
      {:ok, entity} =
        Entities.create_entity(
          %{
            name: "data_cs_radio_strict_test",
            display_name: "Data CS Radio Strict Test",
            display_name_plural: "Data CS Radio Strict Tests",
            fields_definition: [
              %{
                "type" => "radio",
                "key" => "priority",
                "label" => "Priority",
                "options" => ["Low", "High"]
              }
            ],
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: entity.uuid,
          title: "Radio Strict Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"priority" => "Medium"}
        })

      assert errors_on(cs)[:data]
    end
  end

  describe "checkbox field validation" do
    setup ctx do
      {:ok, checkbox_entity} =
        Entities.create_entity(
          %{
            name: "data_cs_checkbox_test",
            display_name: "Data CS Checkbox Test",
            display_name_plural: "Data CS Checkbox Tests",
            fields_definition: [
              %{
                "type" => "checkbox",
                "key" => "tools",
                "label" => "Tools",
                "options" => ["Hammer", "Drill"],
                "allow_other" => true
              }
            ],
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, checkbox_entity: checkbox_entity}
    end

    test "a list of known options is accepted", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.checkbox_entity.uuid,
          title: "Checkbox Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"tools" => ["Hammer", "Drill"]}
        })

      refute errors_on(cs)[:data]
    end

    test "an empty list is accepted (nothing ticked, not required)", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.checkbox_entity.uuid,
          title: "Checkbox Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"tools" => []}
        })

      refute errors_on(cs)[:data]
    end

    test "a value outside options is accepted when allow_other is true", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.checkbox_entity.uuid,
          title: "Checkbox Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"tools" => ["Hammer", "Wrench"]}
        })

      refute errors_on(cs)[:data]
    end

    test "the __other__ sentinel in the list is rejected even with allow_other", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.checkbox_entity.uuid,
          title: "Checkbox Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"tools" => ["Hammer", "__other__"]}
        })

      assert errors_on(cs)[:data]
    end

    test "a list containing a map entry is rejected even with allow_other (M2 follow-up)", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.checkbox_entity.uuid,
          title: "Checkbox Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"tools" => [%{"evil" => "map"}, "Hammer"]}
        })

      assert errors_on(cs)[:data]
    end

    test "without allow_other, a value outside options is rejected", ctx do
      {:ok, entity} =
        Entities.create_entity(
          %{
            name: "data_cs_checkbox_strict_test",
            display_name: "Data CS Checkbox Strict Test",
            display_name_plural: "Data CS Checkbox Strict Tests",
            fields_definition: [
              %{
                "type" => "checkbox",
                "key" => "tools",
                "label" => "Tools",
                "options" => ["Hammer", "Drill"]
              }
            ],
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: entity.uuid,
          title: "Checkbox Strict Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"tools" => ["Hammer", "Wrench"]}
        })

      assert errors_on(cs)[:data]
    end

    test "a scalar value instead of a list is rejected", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.checkbox_entity.uuid,
          title: "Checkbox Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"tools" => "evil"}
        })

      assert errors_on(cs)[:data]
    end
  end

  describe "value-shape guard for text-like fields (M2)" do
    # `validate_field_type/3` used to have NO branch for `text`/
    # `textarea`/`rich_text` — they fell to the catch-all (`_ -> changeset`),
    # so this changeset (the final, unconditional word on what lands in
    # `EntityData.data` — see `LiveDataForm`'s own doc for why every other
    # check is best-effort) had no opinion on their value's shape. A map
    # value would sail straight through and into storage, where both
    # `LiveDataForm` render paths crash rendering it
    # (`Protocol.UndefinedError` — `to_string/1` in readonly, a bare
    # `{@value}` inside `<textarea>` in edit). This is the changeset-layer
    # half of that fix; `LiveDataForm.sanitize_values/2` (component layer)
    # closes the same hole earlier, before a crafted autosave/submit even
    # reaches this changeset.
    setup ctx do
      {:ok, shape_entity} =
        Entities.create_entity(
          %{
            name: "data_cs_shape_test",
            display_name: "Data CS Shape Test",
            display_name_plural: "Data CS Shape Tests",
            fields_definition: [
              %{"type" => "text", "key" => "name", "label" => "Name"},
              %{"type" => "textarea", "key" => "notes", "label" => "Notes"},
              %{"type" => "rich_text", "key" => "body", "label" => "Body"},
              %{"type" => "email", "key" => "email", "label" => "Email"},
              %{"type" => "url", "key" => "site", "label" => "Site"}
            ],
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, shape_entity: shape_entity}
    end

    test "a map value for a text field is rejected", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.shape_entity.uuid,
          title: "Shape Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"name" => %{"evil" => "map"}}
        })

      assert errors_on(cs)[:data]
    end

    test "a map value for a textarea field is rejected", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.shape_entity.uuid,
          title: "Shape Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"notes" => %{"evil" => "map"}}
        })

      assert errors_on(cs)[:data]
    end

    test "a list value for a textarea field is rejected", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.shape_entity.uuid,
          title: "Shape Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"notes" => ["a", "b"]}
        })

      assert errors_on(cs)[:data]
    end

    test "a map value for a rich_text field is rejected", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.shape_entity.uuid,
          title: "Shape Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"body" => %{"evil" => "map"}}
        })

      assert errors_on(cs)[:data]
    end

    test "a map value for an email field is still rejected", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.shape_entity.uuid,
          title: "Shape Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"email" => %{"evil" => "map"}}
        })

      assert errors_on(cs)[:data]
    end

    test "a map value for a url field is still rejected", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.shape_entity.uuid,
          title: "Shape Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"site" => %{"evil" => "map"}}
        })

      assert errors_on(cs)[:data]
    end

    test "an ordinary string value for text/textarea/rich_text is still accepted", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.shape_entity.uuid,
          title: "Shape Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"name" => "Jaan", "notes" => "some notes", "body" => "<p>Hello</p>"}
        })

      refute errors_on(cs)[:data]
    end
  end

  describe "required checkbox field — [] counts as empty" do
    setup ctx do
      {:ok, entity} =
        Entities.create_entity(
          %{
            name: "data_cs_required_checkbox_test",
            display_name: "Data CS Required Checkbox Test",
            display_name_plural: "Data CS Required Checkbox Tests",
            fields_definition: [
              %{
                "type" => "checkbox",
                "key" => "tools",
                "label" => "Tools",
                "options" => ["Hammer", "Drill"],
                "required" => true
              }
            ],
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, required_checkbox_entity: entity}
    end

    test "an empty list is rejected as missing, same as a required text field", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.required_checkbox_entity.uuid,
          title: "Required Checkbox Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"tools" => []}
        })

      assert errors_on(cs)[:data]
    end

    test "a non-empty list satisfies the requirement", ctx do
      cs =
        EntityData.changeset(%EntityData{}, %{
          entity_uuid: ctx.required_checkbox_entity.uuid,
          title: "Required Checkbox Record",
          created_by_uuid: ctx.actor_uuid,
          data: %{"tools" => ["Hammer"]}
        })

      refute errors_on(cs)[:data]
    end
  end
end
