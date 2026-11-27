defmodule PhoenixKitEntities.PublicFormTranslationsTest do
  @moduledoc """
  The public form in the page's language: the `EntityForm` component renders
  the form's texts and the fields' labels, placeholders and help in it, and
  `EntityFormController.submit/2` answers in it. Stored submissions stay flat.
  """
  use PhoenixKitEntities.DataCase, async: false

  require Phoenix.LiveViewTest

  import Phoenix.ConnTest, only: [build_conn: 0, fetch_flash: 1]

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.Components.EntityForm
  alias PhoenixKitEntities.Controllers.EntityFormController
  alias PhoenixKitEntities.EntityData

  @fields [
    %{
      "type" => "text",
      "key" => "name",
      "label" => "Name",
      "placeholder" => "Your name",
      "description" => "We will reply soon",
      "translations" => %{
        "de-DE" => %{
          "label" => "Ihr Name",
          "placeholder" => "Vor- und Nachname",
          "description" => "Wir antworten bald"
        },
        "fr-FR" => %{"label" => "Votre nom"}
      }
    },
    %{
      "type" => "select",
      "key" => "topic",
      "label" => "Topic",
      "options" => ["Sales", "Support"],
      "placeholder" => "Pick one",
      "translations" => %{
        "de-DE" => %{
          "label" => "Thema",
          "placeholder" => "Bitte wählen",
          "options" => %{"Sales" => "Verkauf"}
        }
      }
    }
  ]

  @texts %{
    "public_form_title" => "Contact us",
    "public_form_description" => "We read everything",
    "public_form_submit_text" => "Send",
    "public_form_success_message" => "Thanks, we will be in touch",
    "translations" => %{
      "de-DE" => %{
        "public_form_title" => "Kontakt",
        "public_form_description" => "Wir lesen alles",
        "public_form_submit_text" => "Abschicken",
        "public_form_success_message" => "Danke, wir melden uns"
      },
      # French has a title only: everything else falls back to the primary text.
      "fr-FR" => %{"public_form_title" => "Contactez-nous"}
    }
  }

  setup do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("de-DE")
    {:ok, _} = Languages.add_language("fr-FR")

    admin = Fixtures.admin_fixture()
    {:ok, admin: admin}
  end

  defp create_entity(admin, overrides \\ %{}, fields \\ @fields) do
    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "translated_form",
          display_name: "Translated Form",
          display_name_plural: "Translated Forms",
          status: "published",
          fields_definition: fields,
          settings:
            Map.merge(
              %{
                "public_form_enabled" => true,
                "public_form_fields" => Enum.map(fields, & &1["key"])
              },
              Map.merge(@texts, overrides)
            ),
          created_by_uuid: admin.uuid
        },
        actor_uuid: admin.uuid
      )

    entity
  end

  defp render_form(entity, attributes \\ %{}) do
    Phoenix.LiveViewTest.render_component(&EntityForm.render/1,
      attributes: Map.put(attributes, "entity_slug", entity.name),
      content: nil,
      variant: "default"
    )
    |> LazyHTML.from_fragment()
  end

  defp text_of(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  # The field's own label: the help text sits in a second `label` below.
  defp label_text(document, wrapper),
    do: text_of(document, wrapper <> " label:first-of-type")

  defp attr_of(document, selector, attr) do
    case document |> LazyHTML.query(selector) |> LazyHTML.attribute(attr) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp title(document), do: text_of(document, "h2.card-title")
  defp submit(document), do: text_of(document, "form button[type=submit]")
  defp description(document), do: text_of(document, "p.text-base-content\\/70")

  describe "the component, in the page's language" do
    test "primary language: the flat texts and the fields' own wording, as before", %{
      admin: admin
    } do
      Languages.put_request_locale("en-US")
      document = admin |> create_entity() |> render_form()

      assert title(document) == "Contact us"
      assert description(document) == "We read everything"
      assert submit(document) == "Send"
      assert label_text(document, "#entity-field-name-primary") == "Name"

      assert attr_of(document, "#entity-field-name-primary input[type=text]", "placeholder") ==
               "Your name"

      assert text_of(document, "#entity-field-name-primary .fieldset-label") ==
               "We will reply soon"
    end

    test "a language with translations: texts, labels, placeholders, help and options", %{
      admin: admin
    } do
      Languages.put_request_locale("de-DE")
      document = admin |> create_entity() |> render_form()

      assert title(document) == "Kontakt"
      assert description(document) == "Wir lesen alles"
      assert submit(document) == "Abschicken"

      assert label_text(document, "#entity-field-name-de-DE") == "Ihr Name"

      assert attr_of(document, "#entity-field-name-de-DE input[type=text]", "placeholder") ==
               "Vor- und Nachname"

      assert text_of(document, "#entity-field-name-de-DE .fieldset-label") == "Wir antworten bald"

      assert label_text(document, "#entity-field-topic-de-DE") == "Thema"

      assert text_of(document, "#entity-field-topic-de-DE select option[value='']") ==
               "Bitte wählen"

      assert text_of(document, "#entity-field-topic-de-DE select option[value=Sales]") ==
               "Verkauf"

      # An option with no entry shows as stored.
      assert text_of(document, "#entity-field-topic-de-DE select option[value=Support]") ==
               "Support"
    end

    test "what a language lacks falls back to the primary text, piece by piece", %{admin: admin} do
      Languages.put_request_locale("fr-FR")
      document = admin |> create_entity() |> render_form()

      assert title(document) == "Contactez-nous"
      assert description(document) == "We read everything"
      assert submit(document) == "Send"

      assert label_text(document, "#entity-field-name-fr-FR") == "Votre nom"

      assert attr_of(document, "#entity-field-name-fr-FR input[type=text]", "placeholder") ==
               "Your name"

      assert text_of(document, "#entity-field-name-fr-FR .fieldset-label") == "We will reply soon"
      assert label_text(document, "#entity-field-topic-fr-FR") == "Topic"
    end

    test "an explicit locale attribute beats the page's language", %{admin: admin} do
      Languages.put_request_locale("fr-FR")
      document = admin |> create_entity() |> render_form(%{"locale" => "de-DE"})

      assert title(document) == "Kontakt"
      assert submit(document) == "Abschicken"
      assert attr_of(document, "input[name=_locale]", "value") == "de-DE"
    end

    test "a base code in the locale attribute names the enabled dialect", %{admin: admin} do
      document = admin |> create_entity() |> render_form(%{"locale" => "de"})

      assert title(document) == "Kontakt"
      assert attr_of(document, "input[name=_locale]", "value") == "de-DE"
    end

    test "an unknown or disabled locale falls back to the page's language", %{admin: admin} do
      Languages.put_request_locale("fr-FR")
      entity = create_entity(admin)

      for unknown <- ["ru-RU", "xx", "", "../x"] do
        document = render_form(entity, %{"locale" => unknown})
        assert title(document) == "Contactez-nous"
        assert attr_of(document, "input[name=_locale]", "value") == "fr-FR"
      end
    end

    test "a page language the site does not enable shows the primary texts", %{admin: admin} do
      Languages.put_request_locale("ru-RU")
      document = admin |> create_entity() |> render_form()

      assert title(document) == "Contact us"
      assert submit(document) == "Send"
    end

    test "the default submit text follows the module's Gettext locale", %{admin: admin} do
      entity = create_entity(admin, %{"public_form_submit_text" => nil, "translations" => nil})

      entity = %{
        entity
        | settings: Map.drop(entity.settings, ["public_form_submit_text", "translations"])
      }

      {:ok, _} = Entities.update_entity(entity, %{settings: entity.settings})

      Gettext.with_locale(PhoenixKitEntities.Gettext, "de", fn ->
        assert entity |> render_form() |> submit() == "Absenden"
      end)

      Gettext.with_locale(PhoenixKitEntities.Gettext, "fr", fn ->
        assert entity |> render_form() |> submit() == "Envoyer"
      end)
    end

    test "the posted language rides in a hidden field", %{admin: admin} do
      Languages.put_request_locale("de-DE")
      document = admin |> create_entity() |> render_form()

      assert attr_of(document, "form input[name=_locale]", "type") == "hidden"
      assert attr_of(document, "form input[name=_locale]", "value") == "de-DE"
    end

    test "field inputs keep their names: the submission format does not change", %{admin: admin} do
      Languages.put_request_locale("de-DE")
      document = admin |> create_entity() |> render_form()

      assert attr_of(document, "#entity-field-name-de-DE input[type=text]", "name") ==
               "phoenix_kit_entity_data[data][name]"
    end
  end

  describe "an entity without translations" do
    setup %{admin: admin} do
      entity =
        create_entity(admin, %{"translations" => nil}, [
          %{"type" => "text", "key" => "name", "label" => "Name"}
        ])

      settings = Map.drop(entity.settings, ["translations"])
      {:ok, entity} = Entities.update_entity(entity, %{settings: settings})
      {:ok, entity: entity}
    end

    test "renders the same in every language", %{entity: entity} do
      for locale <- ["en-US", "de-DE", "fr-FR"] do
        Languages.put_request_locale(locale)
        document = render_form(entity)

        assert title(document) == "Contact us"
        assert submit(document) == "Send"
        assert text_of(document, "form .form-field-wrapper label") == "Name"
      end
    end
  end

  describe "a single-language site" do
    test "ignores translations and the locale attribute, and posts no locale", %{admin: admin} do
      entity = create_entity(admin)
      # The Languages module off: one language, so one rendering.
      {:ok, _} = Languages.disable_system()

      document = render_form(entity, %{"locale" => "de-DE"})

      assert title(document) == "Contact us"
      assert document |> LazyHTML.query("input[name=_locale]") |> Enum.empty?()
    end
  end

  describe "the answer after a submit" do
    defp post(entity, extra \\ %{}) do
      params =
        Map.merge(
          %{
            "entity_slug" => entity.name,
            "phoenix_kit_entity_data" => %{"data" => %{"name" => "Ann"}}
          },
          extra
        )

      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> fetch_flash()
      |> EntityFormController.submit(params)
    end

    defp info(conn), do: Phoenix.Flash.get(conn.assigns.flash, :info)
    defp error(conn), do: Phoenix.Flash.get(conn.assigns.flash, :error)

    test "the success message is the posted language's", %{admin: admin} do
      entity = create_entity(admin)

      assert entity |> post(%{"_locale" => "de-DE"}) |> info() == "Danke, wir melden uns"
    end

    test "a language without its own message gets the primary one", %{admin: admin} do
      entity = create_entity(admin)

      assert entity |> post(%{"_locale" => "fr-FR"}) |> info() == "Thanks, we will be in touch"
      assert entity |> post(%{"_locale" => "en-US"}) |> info() == "Thanks, we will be in touch"
      assert entity |> post() |> info() == "Thanks, we will be in touch"
    end

    test "the default message and the module's flashes follow the posted language", %{
      admin: admin
    } do
      entity =
        create_entity(admin, %{"public_form_success_message" => nil, "translations" => nil})

      settings = Map.drop(entity.settings, ["public_form_success_message", "translations"])
      {:ok, entity} = Entities.update_entity(entity, %{settings: settings})

      assert entity |> post(%{"_locale" => "de-DE"}) |> info() == "Formular erfolgreich gesendet!"

      assert entity |> post(%{"_locale" => "fr-FR"}) |> info() ==
               "Formulaire envoyé avec succès !"

      missing = %{entity | name: "nope"}
      assert missing |> post(%{"_locale" => "de-DE"}) |> error() == "Formular nicht gefunden"
      assert missing |> post(%{"_locale" => "fr-FR"}) |> error() == "Formulaire introuvable"
      assert missing |> post() |> error() == "Entity not found"
    end

    test "a language the site does not enable, or a crafted value, is ignored", %{admin: admin} do
      entity = create_entity(admin)
      Languages.put_request_locale("fr-FR")

      # Ignored posted values leave the page's own language in force.
      for crafted <- ["ru-RU", "xx", "", "../../x", %{"x" => "de-DE"}, ["de-DE"], 7] do
        conn = post(entity, %{"_locale" => crafted})
        assert info(conn) == "Thanks, we will be in touch"
      end
    end

    test "a catalogue the module ships is not a language the site enables", %{admin: admin} do
      # Russian has a catalogue here but is not an enabled language: if the
      # check were missing, the module's own flashes would come out in Russian.
      entity = create_entity(admin)
      missing = %{entity | name: "nope"}

      for locale <- ["ru-RU", "ru", "et", "et-EE"] do
        assert missing |> post(%{"_locale" => locale}) |> error() == "Entity not found"
      end

      plain = %{entity | settings: Map.drop(entity.settings, ["public_form_success_message"])}
      {:ok, plain} = Entities.update_entity(entity, %{settings: plain.settings})

      for locale <- ["ru-RU", "ru", "et", "et-EE"] do
        assert plain |> post(%{"_locale" => locale}) |> info() == "Form submitted successfully!"
      end
    end

    test "the process's Gettext locale is put back after the request", %{admin: admin} do
      entity = create_entity(admin)
      Gettext.put_locale(PhoenixKitEntities.Gettext, "et")

      post(entity, %{"_locale" => "de-DE"})
      assert Gettext.get_locale(PhoenixKitEntities.Gettext) == "et"

      # also when the request never reaches the entity
      post(%{entity | name: "nope"}, %{"_locale" => "fr-FR"})
      assert Gettext.get_locale(PhoenixKitEntities.Gettext) == "et"
    end

    test "a refused submission answers in the posted language too", %{admin: admin} do
      entity =
        create_entity(admin, %{
          "public_form_honeypot" => true,
          "public_form_honeypot_action" => "reject_silent"
        })

      conn = post(entity, %{"_locale" => "de-DE", "_hp_website" => "bot"})
      assert info(conn) == "Danke, wir melden uns"
    end

    test "the stored submission is flat, whatever the language", %{admin: admin} do
      entity = create_entity(admin)

      post(entity, %{"_locale" => "de-DE"})

      assert [%{data: data, title: "Ann"}] = EntityData.list_by_entity(entity.uuid)
      assert data == %{"name" => "Ann"}
    end
  end
end
