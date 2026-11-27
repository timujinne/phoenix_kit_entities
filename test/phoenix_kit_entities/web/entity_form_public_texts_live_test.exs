defmodule PhoenixKitEntities.Web.EntityFormPublicTextsLiveTest do
  @moduledoc """
  The builder's public-form texts per language: the primary language's are the
  flat settings, every other language's go to `settings["translations"][lang]`
  through the same language tabs and form params as the entity's own
  translations, and an empty one is dropped (the form falls back to the
  primary text).
  """
  use PhoenixKitEntities.LiveCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitEntities, as: Entities

  @keys ~w(public_form_title public_form_description public_form_submit_text public_form_success_message)

  setup do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("de-DE")
    actor_uuid = Ecto.UUID.generate()

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "pf_texts",
          display_name: "PF Texts",
          display_name_plural: "PF Texts",
          status: "published",
          fields_definition: [%{"type" => "text", "key" => "name", "label" => "Name"}],
          settings: %{
            "public_form_enabled" => true,
            "public_form_fields" => ["name"],
            "public_form_title" => "Contact us",
            "public_form_submit_text" => "Send"
          },
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, entity: entity, actor_uuid: actor_uuid}
  end

  defp open(conn, ctx) do
    conn = put_test_scope(conn, fake_scope(user_uuid: ctx.actor_uuid))
    {:ok, view, _html} = live(conn, "/en/admin/entities/#{ctx.entity.uuid}/edit")
    view
  end

  defp switch_to(view, lang) do
    send(view.pid, {:__multilang_apply_lang__, lang})
    render(view)
  end

  defp translation_input(key, lang), do: "[name='entities[translations][#{lang}][#{key}]']"

  # What a browser posts from another language's tab: that tab's fields only.
  defp save(view, lang, texts) do
    view
    |> form("form[phx-change='validate']", %{"entities" => %{"translations" => %{lang => texts}}})
    |> render_submit()
  end

  defp settings(ctx), do: Entities.get_entity!(ctx.entity.uuid).settings

  test "the primary tab edits the flat texts, with no translation inputs", %{conn: conn} = ctx do
    view = open(conn, ctx)

    for key <- @keys do
      assert has_element?(view, "[name='#{key}']")
      refute has_element?(view, translation_input(key, "de-DE"))
    end

    refute has_element?(view, "#public-form-texts-hint")
  end

  test "another language's tab edits that language's texts, falling back visibly",
       %{conn: conn} = ctx do
    view = open(conn, ctx)
    switch_to(view, "de-DE")

    for key <- @keys do
      assert has_element?(view, translation_input(key, "de-DE"))
      refute has_element?(view, "input[name='#{key}'], textarea[name='#{key}']")
    end

    assert has_element?(view, "#public-form-texts-hint")
    # The primary text shows as the placeholder: that is what an empty field falls back to.
    assert has_element?(
             view,
             "#{translation_input("public_form_title", "de-DE")}[placeholder='Contact us']"
           )

    assert has_element?(
             view,
             "#{translation_input("public_form_submit_text", "de-DE")}[placeholder='Send']"
           )
  end

  test "the texts typed on another tab are saved under that language, flat ones untouched",
       %{conn: conn} = ctx do
    view = open(conn, ctx)
    switch_to(view, "de-DE")

    # Typing validates, and the typed texts are already in the working copy…
    view
    |> form("form[phx-change='validate']", %{
      "entities" => %{"translations" => %{"de-DE" => %{"public_form_title" => "Kontakt"}}}
    })
    |> render_change()

    assert has_element?(
             view,
             "#{translation_input("public_form_title", "de-DE")}[value='Kontakt']"
           )

    # …and the submit stores them.
    save(view, "de-DE", %{
      "public_form_title" => "Kontakt",
      "public_form_description" => "Wir lesen alles",
      "public_form_submit_text" => "Abschicken",
      "public_form_success_message" => "Danke"
    })

    stored = settings(ctx)

    assert stored["translations"]["de-DE"] == %{
             "public_form_title" => "Kontakt",
             "public_form_description" => "Wir lesen alles",
             "public_form_submit_text" => "Abschicken",
             "public_form_success_message" => "Danke"
           }

    assert stored["public_form_title"] == "Contact us"
    assert stored["public_form_submit_text"] == "Send"

    # And they come back when the page is opened again.
    view = open(conn, ctx)
    switch_to(view, "de-DE")

    assert has_element?(
             view,
             "#{translation_input("public_form_title", "de-DE")}[value='Kontakt']"
           )
  end

  test "an emptied text is dropped, so the form falls back to the primary one",
       %{conn: conn} = ctx do
    {:ok, _} =
      Entities.update_entity(ctx.entity, %{
        settings:
          Map.put(ctx.entity.settings, "translations", %{
            "de-DE" => %{
              "public_form_title" => "Kontakt",
              "public_form_submit_text" => "Abschicken"
            }
          })
      })

    view = open(conn, ctx)
    switch_to(view, "de-DE")

    save(view, "de-DE", %{"public_form_title" => ""})

    assert settings(ctx)["translations"]["de-DE"] == %{"public_form_submit_text" => "Abschicken"}
  end

  test "a single-language site has no language tabs and no translation inputs",
       %{conn: conn} = ctx do
    {:ok, _} = Languages.disable_system()
    view = open(conn, ctx)

    assert has_element?(view, "[name='public_form_title']")
    refute has_element?(view, "[name^='entities[translations]'][name$='[public_form_title]']")
    refute has_element?(view, "#public-form-texts-hint")
  end

  describe "saving an unrelated translation" do
    test "keeps the stored public-form texts while the public form is off", %{conn: conn} = ctx do
      {:ok, _} =
        Entities.update_entity(ctx.entity, %{
          settings:
            ctx.entity.settings
            |> Map.put("public_form_enabled", false)
            |> Map.put("translations", %{
              "de-DE" => %{
                "display_name" => "Alt",
                "public_form_title" => "Kontakt",
                "public_form_submit_text" => "Abschicken"
              }
            })
        })

      view = open(conn, ctx)
      switch_to(view, "de-DE")

      # The public-form section is not on the page, so only the entity's own
      # translation is posted.
      refute has_element?(view, translation_input("public_form_title", "de-DE"))
      save(view, "de-DE", %{"display_name" => "Neu"})

      assert settings(ctx)["translations"]["de-DE"] == %{
               "display_name" => "Neu",
               "public_form_title" => "Kontakt",
               "public_form_submit_text" => "Abschicken"
             }
    end

    test "still removes a value whose input was posted empty", %{conn: conn} = ctx do
      {:ok, _} =
        Entities.update_entity(ctx.entity, %{
          settings:
            Map.put(ctx.entity.settings, "translations", %{
              "de-DE" => %{"display_name" => "Alt", "public_form_title" => "Kontakt"}
            })
        })

      view = open(conn, ctx)
      switch_to(view, "de-DE")
      save(view, "de-DE", %{"display_name" => "", "public_form_title" => "Kontakt"})

      assert settings(ctx)["translations"]["de-DE"] == %{"public_form_title" => "Kontakt"}
    end

    test "drops the language entry once nothing is left", %{conn: conn} = ctx do
      {:ok, _} =
        Entities.update_entity(ctx.entity, %{
          settings:
            Map.put(ctx.entity.settings, "translations", %{
              "de-DE" => %{"public_form_title" => "Kontakt"}
            })
        })

      view = open(conn, ctx)
      switch_to(view, "de-DE")
      save(view, "de-DE", %{"public_form_title" => ""})

      refute Map.has_key?(settings(ctx), "translations")
    end
  end

  describe "the primary language's inputs, driven as a browser drives them" do
    @typed %{
      "public_form_title" => "Hello title",
      "public_form_description" => "Hello description",
      "public_form_submit_text" => "Go",
      "public_form_success_message" => "Hello success"
    }

    test "leaving each input saves its text, and Save keeps it", %{conn: conn} = ctx do
      view = open(conn, ctx)

      for {key, value} <- @typed do
        view |> element("[name='#{key}']") |> render_blur(%{"value" => value})
      end

      view
      |> form("form[phx-change='validate']", %{"entities" => %{"display_name" => "PF Texts"}})
      |> render_submit()

      stored = settings(ctx)
      for {key, value} <- @typed, do: assert(stored[key] == value, key)
    end

    test "submitting before blur saves the final primary texts", %{conn: conn} = ctx do
      conn
      |> open(ctx)
      |> form("form[phx-change='validate']", @typed)
      |> render_submit()

      assert Map.take(settings(ctx), @keys) == @typed
    end

    test "the typed text shows in the input after the round trip", %{conn: conn} = ctx do
      view = open(conn, ctx)
      view |> element("[name='public_form_title']") |> render_blur(%{"value" => "Typed"})

      assert has_element?(view, "input[name='public_form_title'][value='Typed']")
    end

    test "only the four public-form texts can be set this way", %{conn: conn} = ctx do
      view = open(conn, ctx)

      render_hook(view, "update_public_form_setting", %{"setting" => "sort_mode", "value" => "x"})
      render_hook(view, "update_public_form_setting", %{"setting" => nil, "value" => "x"})
      render_hook(view, "update_public_form_setting", %{"value" => "x"})

      # The working copy on the socket, not the stored row: nothing was saved.
      working = :sys.get_state(view.pid).socket.assigns.entity.settings
      assert working == ctx.entity.settings
    end
  end
end
