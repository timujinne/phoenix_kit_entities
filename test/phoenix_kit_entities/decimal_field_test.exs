defmodule PhoenixKitEntities.DecimalFieldTest do
  @moduledoc """
  The `decimal` field type — exact numeric, added because `number` casts
  through `Float.parse/1` and silently rounds money. These pin the whole
  round trip: cast, storage shape, and render.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias PhoenixKitEntities.FieldTypes
  alias PhoenixKitEntities.FormBuilder

  defp field(extra \\ %{}) do
    Map.merge(%{"type" => "decimal", "key" => "unit_cost", "label" => "Unit cost"}, extra)
  end

  defp entity(fields), do: %PhoenixKitEntities{fields_definition: fields}

  describe "registration" do
    test "is a registered numeric type with a 4-place default scale" do
      assert "decimal" in FieldTypes.list_types()

      definition = FieldTypes.new_field("decimal", "unit_cost", "Unit cost")
      assert definition["type"] == "decimal"
      assert definition["scale"] == 4
      refute FieldTypes.requires_options?("decimal")
    end

    test "decimal_field/3 builds the same definition" do
      assert %{"type" => "decimal", "key" => "unit_cost", "label" => "Unit cost"} =
               FieldTypes.decimal_field("unit_cost", "Unit cost")
    end
  end

  describe "casting" do
    test "returns a Decimal, not a float" do
      assert {:ok, %Decimal{} = value} = FormBuilder.cast_field(field(), "5.1000")
      assert Decimal.equal?(value, Decimal.new("5.1000"))
    end

    # The reason this type exists: 0.1 + 0.2 through floats is 0.30000000000000004.
    test "preserves a value a float round trip would corrupt" do
      {:ok, a} = FormBuilder.cast_field(field(), "0.1")
      {:ok, b} = FormBuilder.cast_field(field(), "0.2")

      assert Decimal.equal?(Decimal.add(a, b), Decimal.new("0.3"))
    end

    test "keeps trailing zeros — 5.10 is a different price from 5.1 on an invoice" do
      {:ok, value} = FormBuilder.cast_field(field(), "5.1000")
      assert Decimal.to_string(value, :normal) == "5.1000"
    end

    test "accepts a comma decimal separator" do
      assert {:ok, value} = FormBuilder.cast_field(field(), "12,50")
      assert Decimal.equal?(value, Decimal.new("12.50"))
    end

    # Regression: a repeated separator on its own is thousands grouping,
    # not a decimal point — the value must land whole, not padded with
    # fabricated fraction digits read off the tail of the raw text.
    test "a thousands-grouped whole number keeps no fractional digits" do
      assert {:ok, value} = FormBuilder.cast_field(field(), "1,234,567")
      assert Decimal.to_string(value, :normal) == "1234567"

      # European money-style grouping (dot as grouping separator).
      assert {:ok, value} = FormBuilder.cast_field(field(), "1.234.567")
      assert Decimal.to_string(value, :normal) == "1234567"

      assert {:ok, value} = FormBuilder.cast_field(field(), "12,345,678")
      assert Decimal.to_string(value, :normal) == "12345678"
    end

    # Mixed grouping + decimal still resolves the LAST separator as the
    # decimal point and restores exactly its typed fraction length.
    test "grouping plus a decimal separator restores only the true fraction" do
      assert {:ok, value} = FormBuilder.cast_field(field(), "1,234,567.50")
      assert Decimal.to_string(value, :normal) == "1234567.50"

      assert {:ok, value} = FormBuilder.cast_field(field(), "1.234.567,50")
      assert Decimal.to_string(value, :normal) == "1234567.50"
    end

    test "accepts an integer and an already-cast Decimal" do
      assert {:ok, from_int} = FormBuilder.cast_field(field(), 12)
      assert Decimal.equal?(from_int, Decimal.new(12))

      assert {:ok, same} = FormBuilder.cast_field(field(), Decimal.new("3.25"))
      assert Decimal.equal?(same, Decimal.new("3.25"))
    end

    # Found by external review: cast trims, so the changeset guard must too,
    # or a hand-written " 5.1 " casts fine on the way in and is refused on
    # re-save.
    test "accepts a value with surrounding whitespace, the same as storage does" do
      assert {:ok, value} = FormBuilder.cast_field(field(), " 5.1 ")
      assert Decimal.equal?(value, Decimal.new("5.1"))
    end

    # A bound is part of a field definition, which an admin can edit. A typo
    # there must not turn every save of that field into a crash.
    test "an unparseable min or max is ignored rather than raised on" do
      assert {:ok, _} = FormBuilder.cast_field(field(%{"min" => "abc"}), "5")
      assert {:ok, _} = FormBuilder.cast_field(field(%{"max" => "nonsense"}), "5")
    end

    test "rejects text" do
      assert {:error, _} = FormBuilder.cast_field(field(), "abc")
      assert {:error, _} = FormBuilder.cast_field(field(), "12.5kg")
    end

    test "an empty string clears the value" do
      assert {:ok, nil} = FormBuilder.cast_field(field(), "")
    end

    # `number` enforces the same bound (see `FormBuilderValidationTest`)
    # since it moved to the same free-text control.
    test "enforces min and max" do
      bounded = field(%{"min" => 0, "max" => "100.00"})

      assert {:error, _} = FormBuilder.cast_field(bounded, "-1")
      assert {:error, _} = FormBuilder.cast_field(bounded, "100.01")
      assert {:ok, _} = FormBuilder.cast_field(bounded, "0")
      assert {:ok, _} = FormBuilder.cast_field(bounded, "100.00")
    end

    # The integer/float clauses skipped `apply_decimal_bounds` entirely —
    # a raw numeric value (e.g. a JSON API body, which decodes numbers
    # straight to Elixir integers/floats rather than strings) bypassed
    # min/max, the exact "negative money slips through" defect this type
    # exists to prevent.
    test "enforces min and max for integer and float input, not just strings" do
      bounded = field(%{"min" => 0, "max" => "100.00"})

      assert {:error, _} = FormBuilder.cast_field(bounded, -1)
      assert {:error, _} = FormBuilder.cast_field(bounded, 100.01)
      assert {:ok, _} = FormBuilder.cast_field(bounded, 0)
      assert {:ok, _} = FormBuilder.cast_field(bounded, 100.00)
    end

    test "validate_data casts a decimal field on a whole entity" do
      assert {:ok, %{"unit_cost" => %Decimal{} = value}} =
               FormBuilder.validate_data(entity([field()]), %{"unit_cost" => "5.1000"})

      assert Decimal.equal?(value, Decimal.new("5.1000"))
    end
  end

  describe "storage shape" do
    # Jason encodes a Decimal as a QUOTED STRING, so the JSONB round trip
    # is lossless and reads hand back a binary. Both shapes must pass the
    # changeset guard or a saved record could not be re-saved.
    test "a Decimal survives JSON encoding as a string, not a float" do
      assert Jason.encode!(%{"unit_cost" => Decimal.new("5.1000")}) == ~s({"unit_cost":"5.1000"})
      assert %{"unit_cost" => "5.1000"} = Jason.decode!(~s({"unit_cost":"5.1000"}))
    end
  end

  # `decimal_step/1` no longer drives any HTML — `FieldInput` and
  # `FormBuilder` render decimals through `<.decimal_input>` (a plain text
  # control; the browser's own step/constraint validation, which this
  # function used to appease, doesn't apply to it any more). It's kept as
  # a public `FieldTypes` function for hosts still building a native
  # `<input type="number">` themselves, so it's tested directly here
  # instead of through rendered markup.
  describe "decimal_step/1" do
    test "step follows the declared scale" do
      assert FieldTypes.decimal_step(field(%{"scale" => 4})) == "0.0001"
      # A hand-written definition with no scale stays permissive.
      assert FieldTypes.decimal_step(field()) == "any"
      assert FieldTypes.decimal_step(field(%{"scale" => 2})) == "0.01"
    end

    test "an explicit step that admits the declared scale is honoured" do
      assert FieldTypes.decimal_step(field(%{"scale" => 2, "step" => "0.01"})) == "0.01"
      # Finer than the scale is safe too, in string or numeric form.
      assert FieldTypes.decimal_step(field(%{"scale" => 2, "step" => 0.001})) == "0.001"
      # No declared scale, no promise to keep.
      assert FieldTypes.decimal_step(field(%{"step" => "0.5"})) == "0.5"
    end

    test "a step coarser than the scale falls back to the scale" do
      assert FieldTypes.decimal_step(field(%{"scale" => 4, "step" => "0.01"})) == "0.0001"
      assert FieldTypes.decimal_step(field(%{"scale" => 4, "step" => 0.5})) == "0.0001"
    end

    test "an explicit \"any\" turns stepping off" do
      assert FieldTypes.decimal_step(field(%{"scale" => 4, "step" => "any"})) == "any"
    end

    test "junk, zero and negative steps fall back to the scale" do
      for junk <- ["", " ", "abc", "0", "-0.01", "0,01", "0.0001x", "Infinity", 0, -1] do
        assert FieldTypes.decimal_step(field(%{"scale" => 4, "step" => junk})) == "0.0001"
      end
    end
  end

  describe "rendering" do
    defp render_decimal(f, value) do
      render_component(
        fn assigns ->
          ~H"""
          <PhoenixKitEntities.Components.FieldInput.field_input
            field={@field}
            name="supplier_info[unit_cost]"
            value={@value}
          />
          """
        end,
        %{field: f, value: value}
      )
    end

    test "renders a free-text control, not a native number spinner" do
      html = render_decimal(field(), nil)
      assert html =~ ~s(inputmode="decimal")
      refute html =~ ~s(type="number")
    end

    # The "number" type shares the same `<.decimal_input>` render clause
    # in `FieldInput` — pin it directly so a future edit that reverts
    # only that clause back to a native `type="number"` spinner fails a
    # test instead of shipping unnoticed.
    test "the \"number\" type also renders the free-text control" do
      html = render_decimal(field(%{"type" => "number"}), nil)
      assert html =~ ~s(inputmode="decimal")
      refute html =~ ~s(type="number")
    end

    test "renders both a Decimal and the stored string without exponent notation" do
      # Trailing zeros survive — 5.10 is a different price from 5.1 on an
      # invoice — because the value is pre-formatted by
      # `FieldTypes.decimal_input_value/1` before it ever reaches
      # `<.decimal_input>` (which would otherwise normalize a `%Decimal{}`
      # and drop them).
      assert render_decimal(field(), Decimal.new("5.1000")) =~ ~s(value="5.1000")
      assert render_decimal(field(), "5.1000") =~ ~s(value="5.1000")

      # Decimal.to_string/1 defaults to :scientific for small magnitudes;
      # the control's server-side parser will not accept that.
      html = render_decimal(field(), Decimal.new("0.0001"))
      assert html =~ ~s(value="0.0001")
      refute html =~ "E"
    end

    # Float values only come from data written before this type existed.
    # `to_string/1` renders a small one as "1.0e-7", which the parser rejects.
    test "a stored float renders without scientific notation" do
      html = render_decimal(field(), 0.0000001)

      assert html =~ ~s(value="0.0000001")
      # Scoped to the value attribute: the class list contains "bg-base-100",
      # which a bare `=~ "e-"` matches.
      refute html =~ ~r/value="[^"]*e-/
    end
  end
end

defmodule PhoenixKitEntities.DecimalFieldStorageTest do
  @moduledoc """
  The changeset guard for `decimal` values, which needs a persisted
  blueprint to resolve the field definition.

  Jason encodes a `Decimal` as a QUOTED STRING, so the JSONB round trip is
  lossless and reads hand back a binary. Both shapes must pass or a saved
  record could not be re-saved.
  """
  use PhoenixKitEntities.DataCase, async: true

  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData

  setup do
    actor_uuid = Ecto.UUID.generate()

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "decimal_storage_test",
          display_name: "Decimal Storage",
          display_name_plural: "Decimal Storage",
          fields_definition: [
            %{"type" => "decimal", "key" => "unit_cost", "label" => "Unit cost", "scale" => 4}
          ],
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, entity: entity, actor_uuid: actor_uuid}
  end

  defp changeset(ctx, value) do
    EntityData.changeset(%EntityData{}, %{
      entity_uuid: ctx.entity.uuid,
      title: "Row",
      created_by_uuid: ctx.actor_uuid,
      data: %{"unit_cost" => value}
    })
  end

  test "accepts a Decimal, the string it round-trips to, and plain numbers", ctx do
    for value <- [Decimal.new("5.1000"), "5.1000", 5, 5.1] do
      refute errors_on(changeset(ctx, value))[:data],
             "expected #{inspect(value)} to be accepted"
    end
  end

  test "rejects text", ctx do
    assert errors_on(changeset(ctx, "abc"))[:data]
  end

  test "a stored Decimal comes back out as its exact string", ctx do
    {:ok, record} =
      EntityData.create(%{
        entity_uuid: ctx.entity.uuid,
        title: "Row",
        created_by_uuid: ctx.actor_uuid,
        data: %{"unit_cost" => Decimal.new("5.1000")}
      })

    reloaded = EntityData.get!(record.uuid)

    assert reloaded.data["unit_cost"] == "5.1000"
    assert Decimal.equal?(Decimal.new(reloaded.data["unit_cost"]), Decimal.new("5.1000"))
  end
end
