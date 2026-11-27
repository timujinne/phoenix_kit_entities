defmodule PhoenixKitEntities.PublicFormTurnstileSanitizedTest do
  @moduledoc """
  The form inside a Publishing post.

  Publishing renders an inline `<EntityForm>` and then runs the whole page
  through an allow-list HTML sanitizer (`Renderer.Sanitizer.page/1`, in
  `phoenix_kit_publishing`). That list keeps `class`, `id`, `lang`, `title`,
  `dir`, `role`, `style` and `aria-*` on every element, and on `input` only
  `type name value ...`; it drops every `data-*` and `phx-*` attribute,
  `hidden`, and the `noscript` tag (its content comes out as escaped text).

  The module's Turnstile bundle must find its parts by what survives that, so
  this test pushes the component's output through a faithful reproduction of
  the allow-list and asserts what the bundle needs is still there and nothing
  stray is left to show. The reproduction below is COPIED from Publishing
  0.20.0 (`page` profile: the `author` lists plus `@page_tags` and
  `@page_tag_attributes`); it is not a dependency, so if Publishing changes
  its allow-list, update it here and re-check the bundle's selectors
  (`priv/static/assets/phoenix_kit_entities.js`).
  """
  use PhoenixKitEntities.DataCase, async: false

  require Phoenix.LiveViewTest

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.Components.EntityForm
  alias PhoenixKitEntities.Test.TurnstileStub

  @tags ~w(a abbr acronym area article aside b bdi bdo blockquote br caption center cite
           code col colgroup data dd del details dfn div dl dt em figcaption figure footer
           h1 h2 h3 h4 h5 h6 header hgroup hr i img input ins kbd li map mark nav ol p pre q rp rt
           rtc ruby s samp small span strike strong sub summary sup table tbody td tfoot th
           thead time tr tt u ul var wbr)
  @page_tags ~w(section audio video source iframe form label select option optgroup
                textarea button fieldset legend picture)
  @generic_attributes ~w(class id lang title dir role style)
  @generic_prefixes ["aria-"]
  @tag_attributes %{"input" => ~w(type checked disabled)}
  @page_tag_attributes %{
    "form" => ~w(action method enctype novalidate autocomplete name),
    "input" =>
      ~w(name value placeholder required readonly min max step pattern minlength maxlength autocomplete multiple accept),
    "label" => ~w(for),
    "select" => ~w(name required disabled multiple size),
    "option" => ~w(value selected disabled label),
    "textarea" => ~w(name placeholder required readonly disabled rows cols minlength maxlength),
    "button" => ~w(type name value disabled)
  }

  defp sanitize_page(html) do
    MDEx.safe_html(html,
      sanitize: [
        tags: @tags ++ @page_tags,
        tag_attributes:
          Map.merge(@tag_attributes, @page_tag_attributes, fn _tag, a, b -> Enum.uniq(a ++ b) end),
        generic_attributes: @generic_attributes,
        generic_attribute_prefixes: @generic_prefixes,
        url_schemes: ~w(http https mailto tel),
        url_relative: :passthrough,
        link_rel: nil,
        strip_comments: true
      ],
      escape: [content: false, curly_braces_in_code: false]
    )
  end

  setup do
    TurnstileStub.install()
    admin = Fixtures.admin_fixture()
    connection = TurnstileStub.verified_connection!("Contact forms", "0x4AAAA-site-key")

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "sanitized_form",
          display_name: "Sanitized Form",
          display_name_plural: "Sanitized Forms",
          status: "published",
          fields_definition: [%{"type" => "text", "key" => "name", "label" => "Name"}],
          settings: %{
            "public_form_enabled" => true,
            "public_form_fields" => ["name"],
            "public_form_turnstile" => true,
            "public_form_turnstile_connection" => connection
          },
          created_by_uuid: admin.uuid
        },
        actor_uuid: admin.uuid
      )

    html =
      Phoenix.LiveViewTest.render_component(&EntityForm.render/1,
        attributes: %{"entity_slug" => entity.name},
        content: nil,
        variant: "default"
      )

    {:ok, raw: html, clean: html |> sanitize_page() |> LazyHTML.from_fragment()}
  end

  test "the reproduction really is the strict one: it drops what the module avoids", %{raw: raw} do
    cleaned = sanitize_page(raw)

    # The attributes core's own widget element carries, and `hidden`.
    refute cleaned =~ "phx-hook"
    refute cleaned =~ "data-sitekey"
    refute cleaned =~ "phx-update"
    assert raw =~ "phx-hook"
  end

  test "the site key still rides in the form, in a hidden field", %{clean: clean} do
    assert [key] = LazyHTML.query(clean, "form input[name=_turnstile_sitekey]") |> Enum.to_list()
    assert LazyHTML.attribute(key, "type") == ["hidden"]
    assert LazyHTML.attribute(key, "value") == ["0x4AAAA-site-key"]
  end

  test "the widget box, the live region and the texts are still findable by class", %{
    clean: clean
  } do
    assert [_] = LazyHTML.query(clean, "form .entity-turnstile-widget") |> Enum.to_list()

    assert [status] = LazyHTML.query(clean, "form .entity-turnstile-status") |> Enum.to_list()
    assert LazyHTML.attribute(status, "role") == ["status"]

    for kind <- ~w(wait blocked error) do
      assert [_] =
               LazyHTML.query(clean, "form .entity-turnstile-text-#{kind}") |> Enum.to_list()
    end
  end

  test "the texts stay hidden and the live region stays empty: nothing stray is shown",
       %{clean: clean, raw: raw} do
    # Hidden by a plain inline style, which the allow-list keeps.
    assert [wrapper] =
             LazyHTML.query(clean, "form div[style='display: none']") |> Enum.to_list()

    assert wrapper |> LazyHTML.query(".entity-turnstile-text-wait") |> Enum.any?()

    # The live region has no words until the bundle speaks.
    [status] = LazyHTML.query(clean, "form .entity-turnstile-status") |> Enum.to_list()
    assert String.trim(LazyHTML.text(status)) == ""

    # No `noscript` markup comes out as escaped text, and nothing is a visible alert.
    refute raw =~ "<noscript"
    refute LazyHTML.to_html(clean) =~ "&lt;"
    refute LazyHTML.to_html(clean) =~ "JavaScript is required"
    assert clean |> LazyHTML.query("[role=alert]") |> Enum.empty?()
  end
end
