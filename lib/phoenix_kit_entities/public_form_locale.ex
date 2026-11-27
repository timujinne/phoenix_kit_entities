defmodule PhoenixKitEntities.PublicFormLocale do
  @moduledoc """
  The language a public form renders and answers in.

  Texts follow the model the rest of the module uses for per-language content:
  the primary language lives in the flat setting (`"public_form_title"`),
  every other language in `settings["translations"][<language code>]` under the
  same key. A language with no text for a key, or a blank one, falls back to
  the flat value, and entities without translations read exactly as before.

  Translated keys: `"public_form_title"`, `"public_form_description"`,
  `"public_form_submit_text"`, `"public_form_success_message"`. Field labels,
  placeholders and help come from each field's own `"translations"` (see
  `PhoenixKitEntities.FormBuilder`).

  ## Which language

  `resolve/1` answers with one of the site's **enabled** language codes, or
  `nil` when the site is not multilingual:

    1. the `explicit` language, if it names an enabled language — a dialect
       (`"de-DE"`) or just its base (`"de"`); anything else is ignored, so a
       value that came from a visitor (the form's hidden `_locale` field) can
       select among the languages the site already publishes and nothing else;
    2. otherwise the page's own language, `PhoenixKit.Utils.Multilang.current_locale/0`
       (the dialect core's locale hook recorded for the request, else the
       process Gettext locale).

  Stored submissions are not affected by any of this: they stay flat.
  """

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKitEntities.FormBuilder

  @doc """
  The enabled language code to render in, or nil when the site has a single
  language. May be the primary language.
  """
  @spec resolve(term()) :: String.t() | nil
  def resolve(explicit \\ nil) do
    if Multilang.enabled?() do
      enabled = Multilang.enabled_languages()
      match_enabled(explicit, enabled) || match_enabled(Multilang.current_locale(), enabled)
    end
  end

  @doc """
  A text of the public form for `locale`: the language's own non-blank text
  under `key`, else the flat value, else `default`.
  """
  @spec text(map() | nil, String.t(), String.t() | nil, term()) :: term()
  def text(settings, key, locale, default \\ nil) do
    settings = settings || %{}

    translated(settings, key, locale) || nonblank(settings[key]) || default
  end

  @doc """
  The language's own non-blank text under `key`, or nil. The primary language
  has none: it is the flat value.
  """
  @spec translated(map() | nil, String.t(), String.t() | nil) :: String.t() | nil
  def translated(_settings, _key, nil), do: nil

  def translated(settings, key, locale) when is_map(settings) do
    with false <- locale == Multilang.primary_language(),
         %{} = translations <- Map.get(settings, "translations"),
         %{} = entry <- FormBuilder.lookup_translation(translations, locale),
         value when is_binary(value) <- nonblank(entry[key]) do
      value
    else
      _ -> nil
    end
  end

  def translated(_settings, _key, _locale), do: nil

  defp nonblank(value) when is_binary(value) do
    if String.trim(value) != "", do: value
  end

  defp nonblank(_value), do: nil

  @doc """
  The language to hand `FormBuilder` for field texts: `locale` unless it is
  the primary language, whose texts are the fields' own (`nil`, as the form
  has always been built).
  """
  @spec field_language(String.t() | nil) :: String.t() | nil
  def field_language(locale) do
    if locale == Multilang.primary_language(), do: nil, else: locale
  end

  @doc """
  Runs `fun` with the module's Gettext backend in `locale`'s base language, so
  the module's own strings (flash messages, the default submit text) answer in
  the language the form was shown in. `nil` leaves the process locale alone.
  """
  @spec with_gettext(String.t() | nil, (-> result)) :: result when result: term()
  def with_gettext(nil, fun), do: fun.()

  def with_gettext(locale, fun) when is_binary(locale) do
    Gettext.with_locale(PhoenixKitEntities.Gettext, RecipientLocale.global_locale(locale), fun)
  end

  # The enabled code `candidate` names: exact, else an enabled code with the
  # same base language ("de" -> "de-DE"). When several share the base, the
  # primary language wins, then the page's own dialect, then the first by code.
  defp match_enabled(candidate, enabled) when is_binary(candidate) and candidate != "" do
    if candidate in enabled do
      candidate
    else
      base = base(candidate)
      same_base(enabled, base)
    end
  end

  defp match_enabled(_candidate, _enabled), do: nil

  defp same_base(enabled, base) do
    case Enum.filter(enabled, &(base(&1) == base)) do
      [] -> nil
      same -> prefer(same)
    end
  end

  defp prefer(same) do
    primary = Multilang.primary_language()
    page = Multilang.current_locale()

    cond do
      primary in same -> primary
      page in same -> page
      true -> Enum.min(same)
    end
  end

  defp base(code), do: DialectMapper.extract_base(code)
end
