defmodule PhoenixKitEntities.Components.EntityForm do
  @moduledoc """
  Embeddable entity form component for publishing pages.
  Renders a public submission form based on entity configuration.

  ## Usage in .phk files

      <EntityForm entity_slug="contact" />

  ## Attributes

  - `entity_slug` (required) - The slug/name of the entity to render form for
  - `locale` (optional) - a language code to render in (`"de"` or `"de-DE"`);
    must be one of the site's enabled languages, anything else is ignored

  ## Language

  The form renders in the page's language
  (`PhoenixKit.Utils.Multilang.current_locale/0`) or in `locale`: the title,
  description, submit text and success message come from
  `settings["translations"][<lang>]` and the fields' labels, placeholders, help
  and option texts from each field's own `"translations"`, each falling back to
  the primary-language value when the language has none. The module's own
  strings (default submit text, "unavailable" notice) follow the process Gettext
  locale core sets for the page. The language rides in a hidden `_locale` field
  so the controller answers in it. Submissions are stored flat. See
  `PhoenixKitEntities.PublicFormLocale`.

  ## Cloudflare Turnstile

  With `public_form_turnstile` on and a verified connection selected, the form
  carries core's Turnstile widget (`cf-turnstile-response` rides in the POST).
  Inside a LiveView, core's hook (`phx-hook="Turnstile"`) starts it. On a
  controller-rendered page this module's own bundle
  (`priv/static/assets/phoenix_kit_entities.js`, folded into the host's JS by
  core) starts it, and it also keeps a submit that has no token yet from
  leaving the page. The bundle finds the form's parts by class and by a hidden
  `_turnstile_sitekey` field, never by `data-*`/`phx-*` attributes, so the
  markup survives Publishing's page sanitizer (which keeps `class`, `id`,
  `style`, `aria-*` and `input` `type`/`name`/`value`, and drops the rest). The
  host's JavaScript bundle must be on the page either way; without it no
  token is sent and the controller refuses the submission with a message
  saying so. See `PhoenixKitEntities.PublicFormTurnstile`.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitEntities.Gettext

  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.FormBuilder
  alias PhoenixKitEntities.PublicFormLocale
  alias PhoenixKitEntities.PublicFormTurnstile
  alias PhoenixKitWeb.Components.Core.TurnstileWidget

  attr(:content, :string, default: nil)
  attr(:attributes, :map, default: %{})
  attr(:variant, :string, default: "default")

  def render(assigns) do
    entity_slug = Map.get(assigns.attributes, "entity_slug", "")
    locale = PublicFormLocale.resolve(Map.get(assigns.attributes, "locale"))

    # Load entity and check if public form is enabled
    entity = if entity_slug != "", do: Entities.get_entity_by_name(entity_slug), else: nil

    {form_enabled, form_fields, form_title, form_description, form_submit_text, honeypot_enabled} =
      if entity do
        settings = entity.settings || %{}
        fields = Map.get(settings, "public_form_fields", [])
        actually_enabled = form_available?(entity, settings, fields)

        title = PublicFormLocale.text(settings, "public_form_title", locale, "")
        description = PublicFormLocale.text(settings, "public_form_description", locale, "")

        submit_text =
          PublicFormLocale.text(settings, "public_form_submit_text", locale, gettext("Submit"))

        honeypot = Map.get(settings, "public_form_honeypot", false)
        {actually_enabled, fields, title, description, submit_text, honeypot}
      else
        {false, [], "", "", gettext("Submit"), false}
      end

    # Create a form entity with only the public form fields
    form_entity =
      if entity && form_enabled do
        fields_definition = entity.fields_definition || []

        public_fields =
          Enum.filter(fields_definition, fn field ->
            field["key"] in form_fields and field["type"] != "relation"
          end)

        %{entity | fields_definition: public_fields}
      else
        nil
      end

    assigns =
      assigns
      |> assign(:entity_slug, entity_slug)
      |> assign(:locale, locale)
      |> assign(:entity, entity)
      |> assign(:form_entity, form_entity)
      |> assign(:form_enabled, form_enabled)
      |> assign(:form_title, form_title)
      |> assign(:form_description, form_description)
      |> assign(:form_submit_text, form_submit_text)
      |> assign(:honeypot_enabled, honeypot_enabled)
      |> assign(:turnstile_site_key, turnstile_site_key(entity, form_enabled))
      |> assign(:form_timestamp, UtilsDate.utc_now() |> DateTime.to_iso8601())

    ~H"""
    <div class="entity-form-wrapper">
      <%= cond do %>
        <% @entity_slug == "" -> %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body text-center py-8">
              <div class="text-4xl mb-3">⚠️</div>
              <p class="text-base-content/70">{gettext("Form configuration error.")}</p>
            </div>
          </div>
        <% is_nil(@entity) -> %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body text-center py-8">
              <div class="text-4xl mb-3">⚠️</div>
              <p class="text-base-content/70">{gettext("Form configuration error.")}</p>
            </div>
          </div>
        <% !@form_enabled -> %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body text-center py-8">
              <div class="text-4xl mb-3">📝</div>
              <p class="text-base-content/70">{gettext("This form is currently unavailable.")}</p>
            </div>
          </div>
        <% true -> %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <%= if @form_title != "" do %>
                <h2 class="card-title text-2xl mb-2">{@form_title}</h2>
              <% end %>
              <%= if @form_description != "" do %>
                <p class="text-base-content/70 mb-4">{@form_description}</p>
              <% end %>

              <form
                action={PhoenixKit.Utils.Routes.path("/entities/#{@entity_slug}/submit")}
                method="post"
              >
                <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

                <%!-- Form loaded timestamp (always included for metadata) --%>
                <input type="hidden" name="_form_loaded_at" value={@form_timestamp} />

                <%!-- The language the form was shown in, so the answer after the
                     submit is in it too (the controller only accepts an enabled
                     language). --%>
                <input :if={@locale} type="hidden" name="_locale" value={@locale} />

                <%!-- Honeypot field (hidden from humans, bots will fill it) --%>
                <%= if @honeypot_enabled do %>
                  <div style="position: absolute; left: -9999px;" aria-hidden="true">
                    <label for="_hp_website">{gettext("Leave this field empty")}</label>
                    <input
                      type="text"
                      name="_hp_website"
                      id="_hp_website"
                      tabindex="-1"
                      autocomplete="off"
                    />
                  </div>
                <% end %>

                {FormBuilder.build_fields(@form_entity, build_empty_changeset(@entity),
                  wrapper_class: "mb-4",
                  lang_code: PublicFormLocale.field_language(@locale)
                )}

                <%!-- Turnstile. The module's JS finds these by class and by the hidden
                     site-key field only, never by a `data-*` or `phx-*` attribute,
                     because Publishing's page sanitizer strips those from an inline
                     form (it keeps `class`, `id`, `style`, `aria-*`, and `input`
                     `type`/`name`/`value`). Core's widget keeps its own
                     `phx-hook` attributes for LiveViews. --%>
                <%= if @turnstile_site_key do %>
                  <input type="hidden" name="_turnstile_sitekey" value={@turnstile_site_key} />
                  <TurnstileWidget.turnstile_widget
                    id={"entity-form-turnstile-#{@entity_slug}"}
                    site_key={@turnstile_site_key}
                    class="mt-4 entity-turnstile-widget"
                  />
                  <%!-- A live region that exists before it has anything to say. --%>
                  <div class="entity-turnstile-status text-sm text-error mt-2" role="status" aria-live="polite">
                  </div>
                  <%!-- The words the JS puts there. Hidden with an inline style (the
                       sanitizer keeps a plain one), not with `hidden`. --%>
                  <div style="display: none" aria-hidden="true">
                    <span class="entity-turnstile-text-wait">
                      {gettext(
                        "Please wait for the verification to finish, then try again. If you do not see it, reload the page."
                      )}
                    </span>
                    <span class="entity-turnstile-text-blocked">
                      {gettext(
                        "The verification could not load, so this form cannot be sent. Your browser or network is blocking challenges.cloudflare.com: allow it (a content blocker is the usual cause), then reload the page."
                      )}
                    </span>
                    <span class="entity-turnstile-text-error">
                      {gettext("The verification could not start. Please reload the page.")}
                    </span>
                  </div>
                <% end %>

                <div class="fieldset mt-6">
                  <button type="submit" class="btn btn-primary">
                    {@form_submit_text}
                  </button>
                </div>
              </form>
            </div>
          </div>
      <% end %>
    </div>
    """
  end

  # nil unless the form is live and Turnstile is on for it with a connection
  # that can verify.
  defp turnstile_site_key(%{settings: settings}, true), do: PublicFormTurnstile.site_key(settings)
  defp turnstile_site_key(_entity, _form_enabled), do: nil

  # Enabled, with at least one field selected, on an entity that is not
  # archived — the same three things the submit endpoint requires.
  defp form_available?(entity, settings, fields) do
    entity.status != "archived" and Map.get(settings, "public_form_enabled", false) == true and
      fields != []
  end

  defp build_empty_changeset(entity) do
    # Create an empty EntityData changeset for the form
    %EntityData{entity_uuid: entity.uuid, data: %{}}
    |> EntityData.change()
  end
end
