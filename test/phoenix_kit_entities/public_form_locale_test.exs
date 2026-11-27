defmodule PhoenixKitEntities.PublicFormLocaleTest do
  @moduledoc """
  `PublicFormLocale`: which enabled language a public form renders and answers
  in, and how a text of the form is looked up in it.
  """
  use PhoenixKitEntities.DataCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitEntities.PublicFormLocale

  @settings %{
    "public_form_title" => "Contact us",
    "public_form_submit_text" => "Send",
    "translations" => %{
      "de-DE" => %{"public_form_title" => "Kontakt", "public_form_submit_text" => "   "},
      "fr-FR" => %{"public_form_title" => "Contactez-nous"},
      # Another entry's keys never leak into a language that has none of its own.
      "en-US" => %{"public_form_title" => "Primary translation entry"}
    }
  }

  describe "when the site has one language" do
    test "nothing is resolved, whatever is asked" do
      assert PublicFormLocale.resolve() == nil
      assert PublicFormLocale.resolve("de-DE") == nil
    end

    test "texts are the flat ones" do
      assert PublicFormLocale.text(@settings, "public_form_title", nil) == "Contact us"
    end
  end

  describe "when the site is multilingual" do
    setup do
      {:ok, _} = Languages.enable_system()
      {:ok, _} = Languages.add_language("de-DE")
      {:ok, _} = Languages.add_language("fr-FR")
      :ok
    end

    test "an explicit language wins, as the enabled code" do
      assert PublicFormLocale.resolve("de-DE") == "de-DE"
      assert PublicFormLocale.resolve("fr-FR") == "fr-FR"
    end

    test "a bare base language names the enabled dialect" do
      assert PublicFormLocale.resolve("de") == "de-DE"
      assert PublicFormLocale.resolve("fr") == "fr-FR"

      # Whatever was sent, the answer is one of the enabled codes.
      assert PublicFormLocale.resolve("de-XX-whatever") == "de-DE"
    end

    test "with nothing explicit, the page's own language decides" do
      Languages.put_request_locale("fr-FR")
      assert PublicFormLocale.resolve() == "fr-FR"
      assert PublicFormLocale.resolve(nil) == "fr-FR"
      assert PublicFormLocale.resolve("de-DE") == "de-DE"
    end

    test "a language the site does not enable is ignored, and the page's language applies" do
      Languages.put_request_locale("fr-FR")

      for unknown <- [
            "ru-RU",
            "ru",
            "xx",
            "",
            "../../etc",
            nil,
            7,
            %{"x" => "de"},
            ["de"]
          ] do
        assert PublicFormLocale.resolve(unknown) == "fr-FR",
               "#{inspect(unknown)} must not select a language"
      end
    end

    test "a disabled language is not accepted" do
      {:ok, _} = Languages.add_language("es-ES")
      assert PublicFormLocale.resolve("es-ES") == "es-ES"

      {:ok, _} = Languages.disable_language("es-ES")
      refute PublicFormLocale.resolve("es-ES") == "es-ES"
    end

    test "a base code shared by several enabled dialects names the primary, then the page's" do
      {:ok, _} = Languages.add_language("en-GB")
      {:ok, _} = Languages.add_language("de-AT")

      # primary language en-US shares the base with en-GB
      assert PublicFormLocale.resolve("en") == "en-US"

      # no primary among the de-* dialects: the page's own dialect, else the first by code
      Languages.put_request_locale("de-DE")
      assert PublicFormLocale.resolve("de") == "de-DE"

      Languages.put_request_locale("fr-FR")
      assert PublicFormLocale.resolve("de") == "de-AT"
    end

    test "with_gettext/2 restores the locale, also when the function raises" do
      alias PhoenixKitEntities.Gettext, as: Backend
      Gettext.put_locale(Backend, "et")

      assert_raise RuntimeError, fn ->
        PublicFormLocale.with_gettext("de-DE", fn -> raise "boom" end)
      end

      assert Gettext.get_locale(Backend) == "et"
    end

    test "text/4 takes the language's own text, else the flat one, else the default" do
      assert PublicFormLocale.text(@settings, "public_form_title", "de-DE") == "Kontakt"
      assert PublicFormLocale.text(@settings, "public_form_title", "fr-FR") == "Contactez-nous"

      # blank translation -> flat
      assert PublicFormLocale.text(@settings, "public_form_submit_text", "de-DE") == "Send"
      # no key for the language -> flat
      assert PublicFormLocale.text(@settings, "public_form_submit_text", "fr-FR") == "Send"

      for empty <- [nil, "", "   "] do
        settings = Map.put(@settings, "public_form_submit_text", empty)

        assert PublicFormLocale.text(settings, "public_form_submit_text", "de-DE", "Submit") ==
                 "Submit"
      end

      # nothing anywhere -> default
      assert PublicFormLocale.text(@settings, "public_form_description", "de-DE", "") == ""
      assert PublicFormLocale.text(%{}, "public_form_title", "de-DE", "dflt") == "dflt"
      assert PublicFormLocale.text(nil, "public_form_title", "de-DE", "dflt") == "dflt"
    end

    test "the primary language has no translation entry: its text is the flat one" do
      assert PublicFormLocale.text(@settings, "public_form_title", "en-US") == "Contact us"
    end

    test "a translation stored under the base code serves the dialect" do
      settings = %{"translations" => %{"de" => %{"public_form_title" => "Kontakt"}}}
      assert PublicFormLocale.text(settings, "public_form_title", "de-DE") == "Kontakt"
    end

    test "field_language/1 is nil for the primary language" do
      assert PublicFormLocale.field_language("en-US") == nil
      assert PublicFormLocale.field_language(nil) == nil
      assert PublicFormLocale.field_language("de-DE") == "de-DE"
    end

    test "with_gettext/2 answers in the language's base, and leaves nil alone" do
      alias PhoenixKitEntities.Gettext, as: Backend
      require Gettext.Macros

      assert PublicFormLocale.with_gettext("de-DE", fn -> Gettext.get_locale(Backend) end) == "de"
      assert PublicFormLocale.with_gettext(nil, fn -> :untouched end) == :untouched
    end
  end
end
