defmodule PhoenixKitEntities.Components.FieldInputTest do
  @moduledoc """
  The embeddable inline field renderer + its casting counterpart
  (`FormBuilder.cast_field/2`) — the contract hosts like the catalogue's
  attribute-set editor build on. Pure render/cast pins, no DB.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias PhoenixKitEntities.FormBuilder

  defp render_input(field, extra \\ []) do
    assigns =
      Map.merge(
        %{field: field, name: "extras[#{field["key"]}]", value: extra[:value]},
        Map.new(Keyword.delete(extra, :value))
      )

    render_component(
      fn assigns ->
        ~H"""
        <PhoenixKitEntities.Components.FieldInput.field_input
          field={@field}
          name={@name}
          value={@value}
          id={assigns[:id]}
          size={assigns[:size] || "sm"}
          disabled={assigns[:disabled] || false}
          on_pick={assigns[:on_pick]}
          on_clear={assigns[:on_clear]}
          pick_params={assigns[:pick_params] || %{}}
        />
        """
      end,
      assigns
    )
  end

  defp render_input_with_form(field) do
    render_component(
      fn assigns ->
        ~H"""
        <PhoenixKitEntities.Components.FieldInput.field_input
          field={@field}
          name="extras[k]"
          value={nil}
          form="owner-form"
        />
        """
      end,
      %{field: field}
    )
  end

  describe "field_input/1 rendering" do
    test "form attribute forwards onto controls and hidden fallbacks" do
      text = %{"type" => "text", "key" => "k", "label" => "K"}
      assert render_input_with_form(text) =~ ~s(form="owner-form")

      boolean = %{"type" => "boolean", "key" => "b", "label" => "B"}
      html = render_input_with_form(boolean)
      # BOTH the toggle and its hidden false carry the association.
      assert length(String.split(html, ~s(form="owner-form"))) == 3
    end

    test "typed inputs debounce on blur" do
      for type <- ~w(text email url number date) do
        html = render_input(%{"type" => type, "key" => "k", "label" => "K"}, value: nil)
        assert html =~ ~s(phx-debounce="blur")
        assert html =~ ~s(name="extras[k]")
      end

      html = render_input(%{"type" => "textarea", "key" => "k", "label" => "K"})
      assert html =~ ~s(phx-debounce="blur")
    end

    test "boolean pairs the toggle with a hidden false" do
      html = render_input(%{"type" => "boolean", "key" => "wet", "label" => "Wet"}, value: true)
      assert html =~ ~s(type="hidden" name="extras[wet]" value="false")
      assert html =~ "checked"
      assert html =~ "toggle"
    end

    test "select renders options with the current one selected" do
      field = %{
        "type" => "select",
        "key" => "fin",
        "label" => "F",
        "options" => ["Matte", "Gloss"]
      }

      html = render_input(field, value: "Gloss")
      assert html =~ ~s(<option value="Gloss" selected>)
      assert html =~ ~s(<option value="Matte">)
    end

    test "checkbox group keeps the key present via a same-name hidden input" do
      field = %{"type" => "checkbox", "key" => "tags", "label" => "T", "options" => ["a", "b"]}
      html = render_input(field, value: ["b"])
      # The hidden fallback shares the []-name — mixing a scalar and a
      # list name under one key is parser-undefined (panel finding).
      assert html =~ ~s(type="hidden" name="extras[tags][]" value="")
      assert html =~ ~s(name="extras[tags][]")
      assert html =~ "checked"
    end

    test "image renders thumbnail + Change/Clear wired to host events" do
      uuid = Ecto.UUID.generate()

      field = %{"type" => "image", "key" => "swatch", "label" => "Swatch"}

      html =
        render_input(field,
          value: uuid,
          on_pick: "pick_media",
          on_clear: "clear_media",
          pick_params: %{"uuid" => "row-1"}
        )

      assert html =~ "<img"
      assert html =~ ~s(phx-click="pick_media")
      assert html =~ ~s(phx-value-field="swatch")
      assert html =~ ~s(phx-value-uuid="row-1")
      assert html =~ ~s(phx-click="clear_media")
      assert html =~ "Change"

      # No value → Choose, no thumbnail, no Clear.
      empty = render_input(field, on_pick: "pick_media", on_clear: "clear_media")
      refute empty =~ "<img"
      assert empty =~ "Choose"
      refute empty =~ ~s(phx-click="clear_media")

      # Junk value → degrades to Choose, never reaches URLSigner.
      junk = render_input(field, value: "not-a-uuid", on_pick: "pick_media")
      refute junk =~ "<img"
      assert junk =~ "Choose"
    end

    test "heading renders nothing; unknown types degrade to a note" do
      assert render_input(%{"type" => "heading", "key" => "h", "label" => "H"}) =~ ~r/^\s*$/

      html = render_input(%{"type" => "relation", "key" => "r", "label" => "R"})
      assert html =~ "Unsupported field type"
    end

    test "radio group keeps the key present via a hidden empty input" do
      field = %{"type" => "radio", "key" => "fit", "label" => "F", "options" => ["L", "R"]}
      html = render_input(field, value: "R")
      assert html =~ ~s(type="hidden" name="extras[fit]" value="")
      assert html =~ ~s(type="radio")
      assert html =~ "checked"
    end

    test "disabled reaches the hidden fallbacks too" do
      # A disabled control is omitted from submission — if the hidden
      # fallback stayed enabled it would post alone and silently clear
      # the stored value (panel finding, 2026-08-19 review).
      for field <- [
            %{"type" => "boolean", "key" => "k", "label" => "K"},
            %{"type" => "radio", "key" => "k", "label" => "K", "options" => ["a"]},
            %{"type" => "checkbox", "key" => "k", "label" => "K", "options" => ["a"]}
          ] do
        html = render_input(field, disabled: true)
        [hidden] = Regex.run(~r/<input type="hidden"[^>]*>/, html)
        assert hidden =~ "disabled", "hidden fallback not disabled for #{field["type"]}"
      end
    end

    test "the id lands in every branch, including groups and media" do
      for field <- [
            %{"type" => "radio", "key" => "k", "label" => "K", "options" => ["a"]},
            %{"type" => "checkbox", "key" => "k", "label" => "K", "options" => ["a"]},
            %{"type" => "image", "key" => "k", "label" => "K"},
            %{"type" => "mystery", "key" => "k", "label" => "K"}
          ] do
        html = render_input(field, id: "host-given-id")
        assert html =~ ~s(id="host-given-id"), "id dropped for #{field["type"]}"
      end
    end

    test "malformed field maps degrade instead of raising" do
      # Atom keys / missing "type" are outside the contract but must
      # not FunctionClauseError out of the host's render.
      html = render_input_raw(%{type: "text", key: "k"})
      assert html =~ "Unsupported field type"

      assert render_input_raw(%{"key" => "k"}) =~ "Unsupported field type"
    end

    test "pick_params cannot override the reserved field key" do
      field = %{"type" => "image", "key" => "swatch", "label" => "S"}

      html =
        render_input(field, on_pick: "pick", pick_params: %{"field" => "evil", "uuid" => "r1"})

      assert html =~ ~s(phx-value-field="swatch")
      refute html =~ "evil"
      assert html =~ ~s(phx-value-uuid="r1")
    end
  end

  defp render_input_raw(field) do
    render_component(
      fn assigns ->
        ~H"""
        <PhoenixKitEntities.Components.FieldInput.field_input
          field={@field}
          name="extras[k]"
        />
        """
      end,
      %{field: field}
    )
  end

  describe "FormBuilder.cast_field/2" do
    test "coerces per type, blank clears, required still enforced" do
      assert {:ok, 12.5} = FormBuilder.cast_field(%{"type" => "number", "key" => "p"}, "12.5")
      assert {:ok, 12.5} = FormBuilder.cast_field(%{"type" => "number", "key" => "p"}, "12,5")
      assert {:error, _} = FormBuilder.cast_field(%{"type" => "number", "key" => "p"}, "12abc")
      assert {:ok, nil} = FormBuilder.cast_field(%{"type" => "number", "key" => "p"}, "")

      assert {:ok, true} = FormBuilder.cast_field(%{"type" => "boolean", "key" => "b"}, "true")
      assert {:ok, false} = FormBuilder.cast_field(%{"type" => "boolean", "key" => "b"}, "false")

      select = %{"type" => "select", "key" => "s", "options" => ["A", "B"]}
      assert {:ok, "A"} = FormBuilder.cast_field(select, "A")
      assert {:error, _} = FormBuilder.cast_field(select, "C")

      checkbox = %{"type" => "checkbox", "key" => "c", "options" => ["a", "b"]}
      assert {:ok, ["a"]} = FormBuilder.cast_field(checkbox, ["a"])
      # The hidden fallback's "" entry is stripped before membership.
      assert {:ok, ["a"]} = FormBuilder.cast_field(checkbox, ["", "a"])
      assert {:ok, []} = FormBuilder.cast_field(checkbox, [""])
      assert {:ok, []} = FormBuilder.cast_field(checkbox, "")

      assert {:error, _} =
               FormBuilder.cast_field(%{"type" => "text", "key" => "t", "required" => true}, "")
    end

    test "media references accept storage uuids only" do
      uuid = Ecto.UUID.generate()
      image = %{"type" => "image", "key" => "i"}

      assert {:ok, ^uuid} = FormBuilder.cast_field(image, uuid)
      assert {:ok, nil} = FormBuilder.cast_field(image, "")
      assert {:error, _} = FormBuilder.cast_field(image, "not-a-uuid")
      assert {:error, _} = FormBuilder.cast_field(%{"type" => "video", "key" => "v"}, "nope")
    end
  end
end
