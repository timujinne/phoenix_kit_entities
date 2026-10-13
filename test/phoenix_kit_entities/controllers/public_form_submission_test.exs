defmodule PhoenixKitEntities.Controllers.PublicFormSubmissionTest do
  @moduledoc """
  The public form end to end: the `EntityForm` component is rendered, its
  controls are read back the way a browser would encode them, and the
  result is posted to `EntityFormController.submit/2`.

  Every field type the public-form picker offers has a row in `@cases`;
  a type that renders a control the controller cannot store fails here.
  """
  use PhoenixKitEntities.DataCase, async: false

  require Phoenix.LiveViewTest

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.Components.EntityForm
  alias PhoenixKitEntities.Controllers.EntityFormController
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Events
  alias PhoenixKitEntities.FieldTypes
  alias Plug.Conn.Query

  @media_uuid "018f4e2a-7c1b-7d3e-9a4f-5b6c7d8e9f01"
  @public_peer {203, 0, 113, 9}

  # type => {value typed into the form, value expected in storage, values the form must refuse}
  @cases %{
    "text" => {"Hello", "Hello", [String.duplicate("x", 21)]},
    "textarea" => {"two\nlines", "two\nlines", [String.duplicate("x", 20_001)]},
    "email" => {"ann@example.com", "ann@example.com", ["not-an-email"]},
    "url" => {"https://example.com/a", "https://example.com/a", ["example.com"]},
    "rich_text" => {"<p>Hi</p>", "<p>Hi</p>", [String.duplicate("x", 20_001)]},
    "number" => {"42", 42, ["forty-two"]},
    "decimal" => {"2,5", "2.5", ["two and a half"]},
    "boolean" => {"true", true, ["maybe"]},
    "date" => {"2026-02-28", "2026-02-28", ["9999-99-99", "2026-02-30", "28.02.2026"]},
    "select" => {"A", "A", ["Z"]},
    "radio" => {"B", "B", ["Z"]},
    "checkbox" => {["A", "B"], ["A", "B"], [["Z"]]}
  }

  # Offered by the picker, but with nothing a visitor can fill in: `file`
  # renders no control, `image`/`video` only an empty hidden input (the
  # public form has no media picker).
  @no_value_types ~w(file image video)

  setup do
    admin = Fixtures.admin_fixture()
    {:ok, admin: admin}
  end

  defp field(type) do
    base = %{"type" => type, "key" => "f_" <> type, "label" => "The " <> type}

    cond do
      type in ~w(select radio checkbox) -> Map.put(base, "options", ["A", "B"])
      type == "text" -> Map.put(base, "max_length", 20)
      true -> base
    end
  end

  # `types` entries are a type name or a ready field definition.
  defp create_entity(admin, name, types, extra_settings \\ %{}) do
    fields =
      Enum.map(types, fn
        type when is_binary(type) -> field(type)
        %{} = definition -> definition
      end)

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: name,
          display_name: "Public Form",
          display_name_plural: "Public Forms",
          status: "published",
          fields_definition: fields,
          settings:
            Map.merge(
              %{
                "public_form_enabled" => true,
                "public_form_fields" => Enum.map(fields, & &1["key"])
              },
              extra_settings
            ),
          created_by_uuid: admin.uuid
        },
        actor_uuid: admin.uuid
      )

    entity
  end

  # The form's controls in document order, as `{tag, attrs, text}`.
  defp form_controls(entity) do
    html =
      Phoenix.LiveViewTest.render_component(&EntityForm.render/1,
        attributes: %{"entity_slug" => entity.name},
        content: nil,
        variant: "default"
      )

    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("form input[name], form select[name], form textarea[name]")
    |> LazyHTML.to_tree()
    |> Enum.map(fn {tag, attrs, children} ->
      {tag, Map.new(attrs), children}
    end)
  end

  # What a browser sends for an untouched form: text-like inputs and
  # hidden inputs with their value, unticked checkboxes and radios not at
  # all, a select with its first option.
  defp untouched_pairs(controls) do
    Enum.flat_map(controls, fn
      {"input", %{"type" => type}, _} when type in ["checkbox", "radio"] -> []
      {"input", attrs, _} -> [{attrs["name"], attrs["value"] || ""}]
      {"textarea", attrs, children} -> [{attrs["name"], Enum.join(children)}]
      {"select", attrs, _} -> [{attrs["name"], ""}]
    end)
  end

  # Fills one field the way typing/ticking would: the pair goes under the
  # control's own name, after the untouched pairs (a ticked toggle is sent
  # after its hidden "false", exactly as in a browser).
  defp fill_pairs(controls, key, value) do
    scalar = "phoenix_kit_entity_data[data][#{key}]"
    names = Enum.map(controls, fn {_tag, attrs, _} -> attrs["name"] end)

    cond do
      is_list(value) ->
        assert (scalar <> "[]") in names, "the form renders no list control for #{key}"
        Enum.map(value, &{scalar <> "[]", &1})

      scalar in names ->
        [{scalar, value}]

      true ->
        flunk("the form renders no control for #{key}")
    end
  end

  defp submit_form(entity, values, conn_opts \\ []) do
    controls = form_controls(entity)
    filled = Enum.flat_map(values, fn {key, value} -> fill_pairs(controls, key, value) end)

    params =
      (untouched_pairs(controls) ++ filled)
      |> URI.encode_query()
      |> Query.decode()
      |> Map.put("entity_slug", entity.name)

    post(params, conn_opts)
  end

  defp post(params, conn_opts \\ []) do
    conn =
      Phoenix.ConnTest.build_conn(:post, "/", %{})
      |> Map.put(:remote_ip, Keyword.get(conn_opts, :remote_ip, {127, 0, 0, 1}))
      |> Plug.Test.init_test_session(%{})

    conn =
      case conn_opts[:forwarded_for] do
        nil -> conn
        value -> Plug.Conn.put_req_header(conn, "x-forwarded-for", value)
      end

    conn
    |> Phoenix.ConnTest.fetch_flash()
    |> EntityFormController.submit(params)
  end

  defp post_data(entity, data, conn_opts \\ []) do
    post(
      %{"entity_slug" => entity.name, "phoenix_kit_entity_data" => %{"data" => data}},
      conn_opts
    )
  end

  defp records(entity), do: EntityData.list_by_entity(entity.uuid)
  defp info(conn), do: Phoenix.Flash.get(conn.assigns.flash, :info)
  defp error(conn), do: Phoenix.Flash.get(conn.assigns.flash, :error)
  defp stats(entity), do: Entities.get_entity!(entity.uuid).settings["public_form_stats"]

  describe "every field type the picker offers" do
    test "has a row here" do
      offered = Map.keys(FieldTypes.all()) -- ["heading", "relation"]

      assert Enum.sort(offered) ==
               Enum.sort(Map.keys(@cases) ++ @no_value_types)
    end

    for {type, {typed, stored, _invalid}} <- @cases do
      test "#{type}: a valid value typed into the form is stored", %{admin: admin} do
        type = unquote(type)
        entity = create_entity(admin, "pf_ok_#{type}", [type])

        conn = submit_form(entity, %{"f_#{type}" => unquote(Macro.escape(typed))})

        assert info(conn) == "Form submitted successfully!"
        assert [record] = records(entity)
        assert stored_value(record.data["f_#{type}"]) == unquote(Macro.escape(stored))
      end
    end

    for {type, {_typed, _stored, invalid}} <- @cases, bad <- invalid do
      test "#{type}: #{inspect(bad, printable_limit: 24)} is refused", %{admin: admin} do
        type = unquote(type)
        entity = create_entity(admin, "pf_bad_#{type}", [type])

        conn = post_data(entity, %{"f_#{type}" => unquote(Macro.escape(bad))})

        assert error(conn) == "There was an error submitting the form. Please try again."
        assert records(entity) == []
      end
    end

    test "an untouched form with every type stores a record", %{admin: admin} do
      entity = create_entity(admin, "pf_untouched", Map.keys(@cases) ++ @no_value_types)

      conn = submit_form(entity, %{})

      assert info(conn) == "Form submitted successfully!"
      assert [record] = records(entity)
      # The toggle's hidden input is the only control that carries a value.
      assert record.data["f_boolean"] == false
    end

    test "a file field has no control and takes no posted value", %{admin: admin} do
      entity = create_entity(admin, "pf_file", ["text", "file"])

      refute Enum.any?(form_controls(entity), fn {_tag, attrs, _} ->
               attrs["name"] =~ "f_file"
             end)

      conn =
        post_data(entity, %{
          "f_text" => "kept",
          "f_file" => [%{"filename" => "a.pdf", "nested" => %{"deep" => "x"}}]
        })

      assert info(conn) == "Form submitted successfully!"
      assert [record] = records(entity)
      assert record.data == %{"f_text" => "kept"}
    end

    for type <- ~w(image video) do
      test "#{type}: a posted media uuid is not stored, through the form or past it", %{
        admin: admin
      } do
        type = unquote(type)
        entity = create_entity(admin, "pf_media_#{type}", ["text", type])

        # Through the form: the uuid goes in the field's own hidden input.
        conn = submit_form(entity, %{"f_text" => "kept", "f_#{type}" => @media_uuid})
        assert info(conn) == "Form submitted successfully!"

        # Past it: a hand-built body.
        conn = post_data(entity, %{"f_text" => "kept", "f_#{type}" => @media_uuid})
        assert info(conn) == "Form submitted successfully!"

        assert [first, second] = records(entity)
        assert first.data == %{"f_text" => "kept"}
        assert second.data == %{"f_text" => "kept"}
      end
    end
  end

  # `number` stores a float or an integer, `decimal` a Decimal that JSONB
  # hands back as its canonical string.
  defp stored_value(%Decimal{} = value), do: Decimal.to_string(value)
  defp stored_value(value) when is_float(value), do: trunc(value)
  defp stored_value(value), do: value

  describe "boolean shapes" do
    for {posted, stored} <- [
          {"true", true},
          {"false", false},
          {"on", true},
          {"1", true},
          {"0", false},
          {["false", "true"], true},
          {["false"], false}
        ] do
      test "#{inspect(posted)} is stored as #{stored}", %{admin: admin} do
        entity = create_entity(admin, "pf_bool", ["boolean"])

        conn = post_data(entity, %{"f_boolean" => unquote(posted)})

        assert info(conn) == "Form submitted successfully!"
        assert [record] = records(entity)
        assert record.data["f_boolean"] === unquote(stored)
      end
    end

    for posted <- ["maybe", ["true", %{"x" => "1"}], %{"x" => "true"}] do
      test "#{inspect(posted)} is refused", %{admin: admin} do
        entity = create_entity(admin, "pf_bool_bad", ["boolean"])

        conn = post_data(entity, %{"f_boolean" => unquote(Macro.escape(posted))})

        assert error(conn) == "There was an error submitting the form. Please try again."
        assert records(entity) == []
      end
    end

    test "a ticked toggle on the real form is stored as true", %{admin: admin} do
      entity = create_entity(admin, "pf_bool_form", ["boolean"])

      submit_form(entity, %{"f_boolean" => "true"})

      assert [%{data: %{"f_boolean" => true}}] = records(entity)
    end
  end

  describe "an archived entity" do
    test "refuses the submission like a disabled form", %{admin: admin} do
      entity = create_entity(admin, "pf_archived", ["text"])
      {:ok, entity} = Entities.update_entity(entity, %{"status" => "archived"})

      conn = post_data(entity, %{"f_text" => "x"})

      assert error(conn) == "Public form is not enabled for this entity"
      assert records(entity) == []
    end

    test "renders the unavailable notice instead of the form", %{admin: admin} do
      entity = create_entity(admin, "pf_archived_form", ["text"])
      {:ok, entity} = Entities.update_entity(entity, %{"status" => "archived"})

      assert form_controls(entity) == []
    end
  end

  describe "submission statistics" do
    test "N submissions count N, with no entity edit recorded or announced", %{admin: admin} do
      entity = create_entity(admin, "pf_stats", ["text"])
      Events.subscribe_to_entities()

      for i <- 1..7, do: post_data(entity, %{"f_text" => "n#{i}"})

      assert %{"total_submissions" => 7, "successful_submissions" => 7} = stats(entity)
      assert {:ok, _, _} = DateTime.from_iso8601(stats(entity)["last_submission_at"])

      refute_activity_logged("entity.updated", resource_uuid: entity.uuid)
      refute_received {:entity_updated, _}
    end

    test "a setting saved while a request was in flight survives the bump", %{admin: admin} do
      entity = create_entity(admin, "pf_stats_race", ["text"])

      {:ok, _} =
        Entities.update_entity(
          entity,
          %{"settings" => Map.put(entity.settings, "public_form_title", "Saved meanwhile")},
          actor_uuid: admin.uuid
        )

      # `entity` is now the stale snapshot a request loaded before the save.
      assert :ok = Entities.bump_public_form_stats(entity.uuid, ["total_submissions"])
      assert :ok = Entities.bump_public_form_stats(entity.uuid, ["total_submissions"])

      settings = Entities.get_entity!(entity.uuid).settings
      assert settings["public_form_title"] == "Saved meanwhile"
      assert settings["public_form_stats"]["total_submissions"] == 2
    end

    test "a bump leaves date_updated alone", %{admin: admin} do
      entity = create_entity(admin, "pf_stats_date", ["text"])
      before = Entities.get_entity!(entity.uuid).date_updated

      Entities.bump_public_form_stats(entity.uuid, ["total_submissions"])

      assert Entities.get_entity!(entity.uuid).date_updated == before
    end

    test "a honeypot rejection is counted with its trigger", %{admin: admin} do
      entity = create_entity(admin, "pf_stats_hp", ["text"], %{"public_form_honeypot" => true})

      post(%{
        "entity_slug" => entity.name,
        "_hp_website" => "bot",
        "phoenix_kit_entity_data" => %{"data" => %{"f_text" => "x"}}
      })

      assert records(entity) == []

      assert %{
               "total_submissions" => 1,
               "rejected_submissions" => 1,
               "honeypot_triggers" => 1
             } = stats(entity)

      refute_activity_logged("entity.updated", resource_uuid: entity.uuid)
    end

    test "requests the rate limiter refused write nothing", %{admin: admin} do
      entity = create_entity(admin, "pf_stats_rl", ["text"], %{"public_form_rate_limit" => true})

      errors =
        for i <- 1..9 do
          entity |> post_data(%{"f_text" => "n#{i}"}, remote_ip: @public_peer) |> error()
        end

      assert Enum.count(errors, &is_nil/1) == 5
      assert Enum.count(errors, &(&1 == "Too many submissions. Please try again later.")) == 4

      assert length(records(entity)) == 5
      assert %{"total_submissions" => 5, "successful_submissions" => 5} = stats(entity)
      refute Map.has_key?(stats(entity), "rejected_submissions")
      refute Map.has_key?(stats(entity), "rate_limited_triggers")
    end
  end

  describe "the rate-limit key" do
    setup %{admin: admin} do
      entity =
        create_entity(admin, "pf_rl_#{System.unique_integer([:positive])}", ["text"], %{
          "public_form_rate_limit" => true
        })

      {:ok, entity: entity}
    end

    defp limited(entity, conn_opts_fun) do
      for i <- 1..8 do
        entity |> post_data(%{"f_text" => "n#{i}"}, conn_opts_fun.(i)) |> error()
      end
      |> Enum.count(&(&1 == "Too many submissions. Please try again later."))
    end

    test "a direct client rotating X-Forwarded-For stays in one bucket", %{entity: entity} do
      assert limited(entity, fn i ->
               [remote_ip: @public_peer, forwarded_for: "198.51.100.#{i}"]
             end) == 3
    end

    test "behind a proxy, a client-supplied leading entry buys no new bucket", %{entity: entity} do
      assert limited(entity, fn i ->
               [remote_ip: {127, 0, 0, 1}, forwarded_for: "198.51.100.#{i}, 203.0.113.50"]
             end) == 3
    end

    test "behind a proxy, visitors the proxy names apart get their own buckets", %{
      entity: entity
    } do
      assert limited(entity, fn i ->
               [remote_ip: {10, 0, 0, 2}, forwarded_for: "203.0.113.#{i}"]
             end) == 0
    end
  end

  describe "submission metadata" do
    test "records the TCP peer for a direct client, whatever the header says", %{admin: admin} do
      entity = create_entity(admin, "pf_meta_direct", ["text"])

      post_data(entity, %{"f_text" => "x"}, remote_ip: @public_peer, forwarded_for: "8.8.8.8")

      assert [record] = records(entity)
      assert record.metadata["ip_address"] == "203.0.113.9"
      assert record.metadata["source"] == "public_form"
    end

    test "records the address the proxy appended when the peer is a proxy", %{admin: admin} do
      entity = create_entity(admin, "pf_meta_proxy", ["text"])

      post_data(entity, %{"f_text" => "x"},
        remote_ip: {127, 0, 0, 1},
        forwarded_for: "9.9.9.9, 203.0.113.7"
      )

      assert [record] = records(entity)
      assert record.metadata["ip_address"] == "203.0.113.7"
    end
  end

  describe "value sizes on the public path" do
    test "a text value over the field's max_length is refused, one at it is kept", %{
      admin: admin
    } do
      entity = create_entity(admin, "pf_len", ["text"])

      assert entity |> post_data(%{"f_text" => String.duplicate("é", 21)}) |> error()
      assert records(entity) == []

      assert entity |> post_data(%{"f_text" => String.duplicate("é", 20)}) |> info()
      assert [_] = records(entity)
    end

    test "max_length counts characters: multibyte text at the limit is kept, one over refused",
         %{admin: admin} do
      long = %{"type" => "textarea", "key" => "f_long", "label" => "Long", "max_length" => 7000}
      entity = create_entity(admin, "pf_len_cjk", [long])

      # 7,000 three-byte characters: 21,000 bytes, past the flat ceiling.
      at_limit = String.duplicate("語", 7000)

      assert entity |> post_data(%{"f_long" => at_limit <> "語"}) |> error()
      assert records(entity) == []

      assert entity |> post_data(%{"f_long" => at_limit}) |> info()
      assert [%{data: %{"f_long" => ^at_limit}}] = records(entity)
    end

    test "a field with no max_length keeps the flat byte ceiling for multibyte text", %{
      admin: admin
    } do
      entity = create_entity(admin, "pf_flat_cjk", ["textarea"])

      assert entity |> post_data(%{"f_textarea" => String.duplicate("語", 6667)}) |> error()
      assert records(entity) == []

      assert entity |> post_data(%{"f_textarea" => String.duplicate("語", 6666)}) |> info()
      assert [_] = records(entity)
    end

    test "a checkbox list longer than the cap is refused", %{admin: admin} do
      entity = create_entity(admin, "pf_list", ["checkbox"])

      conn = post_data(entity, %{"f_checkbox" => List.duplicate("A", 101)})

      assert error(conn)
      assert records(entity) == []
    end
  end
end
