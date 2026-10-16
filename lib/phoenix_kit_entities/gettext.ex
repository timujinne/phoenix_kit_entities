defmodule PhoenixKitEntities.Gettext do
  @moduledoc """
  Gettext backend for `phoenix_kit_entities`.

  Owns the translation catalogues under `priv/gettext/`. Locale is set
  per-request by the parent application; this module is only responsible
  for looking msgids up against the active locale.

  See `guides/per-module-i18n.md` in the `phoenix_kit` core guides for
  the full setup and conventions. In short: every module that ships
  Gettext-wrapped UI must own its own backend rather than reaching for
  `PhoenixKitWeb.Gettext` — that backend belongs to core and its
  catalogues live in core's own package, so strings extracted against it
  from here would never end up in any `.po` file this package ships.
  """
  # One compiled module per locale and domain: the catalogues are large, and
  # split modules compile in parallel instead of one long serial compile that
  # blocks every app depending on this package. Lookups are unchanged.
  use Gettext.Backend,
    otp_app: :phoenix_kit_entities,
    split_module_by: [:locale, :domain]
end
