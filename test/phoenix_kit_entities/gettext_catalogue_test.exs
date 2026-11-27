defmodule PhoenixKitEntities.GettextCatalogueTest do
  @moduledoc """
  Guards the shipped `.po` catalogues against silent rot.

  `mix gettext.extract --merge` marks an entry `fuzzy` when a msgid it
  used to match got reworded — the old msgstr is kept (tagged `fuzzy`) so a
  human can review it. The compiled catalogue only drops `obsolete` entries
  (`Gettext.Compiler` filters strictly on `obsolete: false`); a `fuzzy`
  entry keeps compiling and serving the *stale* translation with no runtime
  signal that anything is wrong. Demonstrated during review: rewording a
  source string and re-running `mix gettext.extract --merge` left the
  reworded msgid resolving to the *old* English text via a fuzzy match.

  This test is the guard the compiler doesn't provide — it fails loudly the
  moment any shipped catalogue (including `en/`, which this package ships
  alongside `et/`, `ru/`, `de/` and `fr/` even though `msgstr == msgid`
  there) picks up a
  `fuzzy` entry, so the stale translation gets caught before release
  instead of silently shipping.

  The catalogues are hand-maintained (no `mix gettext.extract` in this
  repo's workflow), so two more invariants nothing else re-checks are
  pinned here as well: no entry may ship with an empty `msgstr` (a
  hand-added msgid that never got its translations renders as the raw
  msgid), and no `msgstr` may interpolate a `%{binding}` the msgid does
  not declare (Gettext raises a missing-binding error at runtime for
  those — omitting a binding is fine, inventing one is not).
  """

  use ExUnit.Case, async: true

  @locales ["en", "et", "ru", "de", "fr"]

  for locale <- @locales do
    test "priv/gettext/#{locale}/LC_MESSAGES/default.po has no fuzzy entries" do
      locale = unquote(locale)

      po_path =
        Application.app_dir(
          :phoenix_kit_entities,
          "priv/gettext/#{locale}/LC_MESSAGES/default.po"
        )

      assert File.exists?(po_path), "expected catalogue at #{po_path}"

      %Expo.Messages{messages: messages} = Expo.PO.parse_file!(po_path)

      fuzzy_msgids =
        messages
        |> Enum.filter(&Expo.Message.has_flag?(&1, "fuzzy"))
        |> Enum.map(&msgid_text/1)

      assert fuzzy_msgids == [],
             "#{locale}/default.po has fuzzy (stale) translations for: " <>
               Enum.join(fuzzy_msgids, ", ") <>
               " — run `mix gettext.extract --merge`, fix each msgstr by hand, " <>
               "and remove the fuzzy flag."
    end

    test "priv/gettext/#{locale}/LC_MESSAGES/default.po has no empty msgstr" do
      empty_msgids =
        unquote(locale)
        |> parse_catalogue()
        |> Enum.reject(&translated?/1)
        |> Enum.map(&msgid_text/1)

      assert empty_msgids == [],
             "#{unquote(locale)}/default.po has untranslated (empty msgstr) entries for: " <>
               Enum.join(empty_msgids, ", ") <>
               " — the catalogues are hand-maintained; fill every msgstr when adding a msgid."
    end

    test "priv/gettext/#{locale}/LC_MESSAGES/default.po msgstr bindings all exist in msgid" do
      offenders =
        unquote(locale)
        |> parse_catalogue()
        |> Enum.reject(&bindings_subset_of_msgid?/1)
        |> Enum.map(&msgid_text/1)

      assert offenders == [],
             "#{unquote(locale)}/default.po has msgstr entries interpolating a binding " <>
               "their msgid does not declare (runtime missing-binding error): " <>
               Enum.join(offenders, ", ")
    end
  end

  defp parse_catalogue(locale) do
    po_path =
      Application.app_dir(
        :phoenix_kit_entities,
        "priv/gettext/#{locale}/LC_MESSAGES/default.po"
      )

    %Expo.Messages{messages: messages} = Expo.PO.parse_file!(po_path)
    messages
  end

  defp translated?(%Expo.Message.Singular{msgstr: msgstr}),
    do: IO.iodata_to_binary(msgstr) != ""

  defp translated?(%Expo.Message.Plural{msgstr: forms}) do
    forms != %{} and Enum.all?(forms, fn {_i, form} -> IO.iodata_to_binary(form) != "" end)
  end

  defp bindings_subset_of_msgid?(%Expo.Message.Singular{msgid: msgid, msgstr: msgstr}) do
    MapSet.subset?(bindings(msgstr), bindings(msgid))
  end

  defp bindings_subset_of_msgid?(%Expo.Message.Plural{} = msg) do
    declared = MapSet.union(bindings(msg.msgid), bindings(msg.msgid_plural))
    Enum.all?(msg.msgstr, fn {_i, form} -> MapSet.subset?(bindings(form), declared) end)
  end

  defp bindings(iodata) do
    ~r/%\{([^}]+)\}/
    |> Regex.scan(IO.iodata_to_binary(iodata), capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  defp msgid_text(%Expo.Message.Singular{msgid: msgid}), do: IO.iodata_to_binary(msgid)
  defp msgid_text(%Expo.Message.Plural{msgid: msgid}), do: IO.iodata_to_binary(msgid)
end
