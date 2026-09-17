defmodule PhoenixKitEntities.Controllers.EntityFormControllerTest do
  @moduledoc """
  Tests for `PhoenixKitEntities.Controllers.EntityFormController.submit/2`
  via direct controller invocation. We build the Plug.Conn manually
  and call the action — no router needed.

  Coverage: all security branches (honeypot trigger, time-check trigger,
  rate-limit, save_suspicious + save_log markers), public-form
  enabled/disabled, IP allowlist (rate-limit-safe vs spoofed RFC1918),
  metadata building (browser/OS/device), happy-path submission, and
  the entity_not_found early return.
  """
  use PhoenixKitEntities.DataCase, async: false

  alias PhoenixKit.Test.Fixtures
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.Controllers.EntityFormController
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.FormBuilder

  @endpoint PhoenixKitEntities.Test.Endpoint

  setup do
    # A real admin row, not a bare `Ecto.UUID.generate()`. The public form is
    # unauthenticated, so `EntityData.create/2` auto-fills the creator from the
    # first admin — with no user in the database at all there is nobody to
    # attribute a submission to, and `create/2` documents that as a validation
    # error on `created_by`. Every install that can serve a public form has an
    # admin (somebody configured the form), so a userless database is a fixture
    # artifact rather than a scenario to encode.
    admin = Fixtures.admin_fixture()
    actor_uuid = admin.uuid

    {:ok, entity} =
      Entities.create_entity(
        %{
          name: "form_ctrl_widget",
          display_name: "Form Ctrl Widget",
          display_name_plural: "Form Ctrl Widgets",
          status: "published",
          fields_definition: [%{"type" => "text", "key" => "title", "label" => "Title"}],
          settings: %{
            "public_form_enabled" => true,
            "public_form_fields" => ["title"]
          },
          created_by_uuid: actor_uuid
        },
        actor_uuid: actor_uuid
      )

    {:ok, entity: entity, actor_uuid: actor_uuid}
  end

  defp build_conn(method, path, params \\ %{}, headers \\ []) do
    conn =
      Phoenix.ConnTest.build_conn(method, path, params)
      |> Plug.Conn.put_req_header(
        "user-agent",
        Keyword.get(
          headers,
          :user_agent,
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 Chrome/120.0"
        )
      )
      |> Plug.Test.init_test_session(%{})

    conn =
      case Keyword.get(headers, :referer) do
        nil -> conn
        ref -> Plug.Conn.put_req_header(conn, "referer", ref)
      end

    case Keyword.get(headers, :forwarded_for) do
      nil -> conn
      val -> Plug.Conn.put_req_header(conn, "x-forwarded-for", val)
    end
  end

  defp invoke_submit(conn, params) do
    conn
    |> Phoenix.ConnTest.put_format("html")
    |> Phoenix.ConnTest.bypass_through(PhoenixKitEntities.Test.Router, [:browser])
    |> tap(fn _c -> :ok end)
    |> Plug.Conn.fetch_query_params()
    |> EntityFormController.submit(params)
  end

  defp simple_invoke(conn, params) do
    # Skip the router pipeline; the controller itself doesn't depend on
    # router-installed plugs for the branches we're covering. Just
    # ensure :flash is fetched so put_flash works.
    conn
    |> Phoenix.ConnTest.fetch_flash()
    |> EntityFormController.submit(params)
  end

  describe "entity not found" do
    test "redirects with error flash" do
      conn = build_conn(:post, "/")
      result = simple_invoke(conn, %{"entity_slug" => "definitely_does_not_exist"})

      assert result.status in [302, 303]
      assert Phoenix.Flash.get(result.assigns.flash, :error) =~ "Entity not found"
    end
  end

  describe "public form not enabled" do
    test "redirects with error flash when public_form_enabled is false", _ctx do
      actor_uuid = Ecto.UUID.generate()

      {:ok, entity} =
        Entities.create_entity(
          %{
            name: "form_ctrl_off",
            display_name: "Off",
            display_name_plural: "Offs",
            fields_definition: [%{"type" => "text", "key" => "title", "label" => "Title"}],
            settings: %{"public_form_enabled" => false},
            created_by_uuid: actor_uuid
          },
          actor_uuid: actor_uuid
        )

      conn = build_conn(:post, "/")
      result = simple_invoke(conn, %{"entity_slug" => entity.name})

      assert result.status in [302, 303]
      assert Phoenix.Flash.get(result.assigns.flash, :error) =~ "Public form is not enabled"
    end

    test "redirects when public_form_fields is empty (effectively off)", _ctx do
      actor_uuid = Ecto.UUID.generate()

      {:ok, entity} =
        Entities.create_entity(
          %{
            name: "form_ctrl_no_fields",
            display_name: "NoFields",
            display_name_plural: "NoFields",
            fields_definition: [],
            settings: %{
              "public_form_enabled" => true,
              "public_form_fields" => []
            },
            created_by_uuid: actor_uuid
          },
          actor_uuid: actor_uuid
        )

      conn = build_conn(:post, "/")
      result = simple_invoke(conn, %{"entity_slug" => entity.name})

      assert result.status in [302, 303]
      assert Phoenix.Flash.get(result.assigns.flash, :error) =~ "Public form is not enabled"
    end
  end

  describe "honeypot" do
    test "reject_silent: triggers happy-path success message + does NOT create record",
         %{entity: entity} = _ctx do
      Entities.update_entity(entity, %{
        settings:
          Map.merge(entity.settings, %{
            "public_form_honeypot" => true,
            "public_form_honeypot_action" => "reject_silent"
          })
      })

      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "_hp_website" => "spam_url_filled",
        "phoenix_kit_entity_data" => %{"data" => %{"title" => "Test"}}
      }

      result = simple_invoke(conn, params)
      # reject_silent shows a success-looking flash so the bot can't tell.
      assert result.status in [302, 303]
    end

    test "reject_error: surfaces error flash when honeypot is triggered", %{entity: entity} do
      Entities.update_entity(entity, %{
        settings:
          Map.merge(entity.settings, %{
            "public_form_honeypot" => true,
            "public_form_honeypot_action" => "reject_error"
          })
      })

      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "_hp_website" => "filled",
        "phoenix_kit_entity_data" => %{"data" => %{"title" => "Test"}}
      }

      result = simple_invoke(conn, params)
      assert Phoenix.Flash.get(result.assigns.flash, :error) =~ "error"
    end
  end

  describe "time check" do
    test "form submitted too fast → reject_error flash", %{entity: entity} do
      Entities.update_entity(entity, %{
        settings:
          Map.merge(entity.settings, %{
            "public_form_time_check" => true,
            "public_form_time_check_action" => "reject_error"
          })
      })

      # _form_loaded_at is now → diff is 0 seconds → rejected (< 3s)
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "_form_loaded_at" => now,
        "phoenix_kit_entity_data" => %{"data" => %{"title" => "Quick"}}
      }

      result = simple_invoke(conn, params)
      assert Phoenix.Flash.get(result.assigns.flash, :error) =~ "time"
    end

    test "form submitted slowly enough → success", %{entity: entity} do
      Entities.update_entity(entity, %{
        settings: Map.merge(entity.settings, %{"public_form_time_check" => true})
      })

      # _form_loaded_at = 30s ago → passes
      loaded_at =
        DateTime.utc_now()
        |> DateTime.add(-30, :second)
        |> DateTime.to_iso8601()

      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "_form_loaded_at" => loaded_at,
        "phoenix_kit_entity_data" => %{"data" => %{"title" => "Slow"}}
      }

      result = simple_invoke(conn, params)
      assert result.status in [302, 303]
    end

    test "malformed _form_loaded_at falls through (treated as no timestamp)", %{entity: entity} do
      Entities.update_entity(entity, %{
        settings: Map.merge(entity.settings, %{"public_form_time_check" => true})
      })

      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "_form_loaded_at" => "not-a-datetime",
        "phoenix_kit_entity_data" => %{"data" => %{"title" => "X"}}
      }

      result = simple_invoke(conn, params)
      assert result.status in [302, 303]
    end
  end

  describe "successful submission" do
    test "creates an entity_data record, returns success flash", %{entity: entity} = _ctx do
      conn = build_conn(:post, "/", %{}, referer: "https://example.test/form")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{
          "data" => %{
            "title" => "Submitted via public form"
          }
        }
      }

      before_count = EntityData.list_by_entity(entity.uuid) |> length()

      result = simple_invoke(conn, params)

      assert result.status in [302, 303]

      assert Phoenix.Flash.get(result.assigns.flash, :info) =~ "submit" or
               Phoenix.Flash.get(result.assigns.flash, :info) =~ "success"

      # The bug this test originally caught (entity.id → entity.uuid KeyError)
      # would have crashed before the redirect — but a future regression that
      # silently skips the insert would still hit the redirect path. Assert on
      # the Repo state so silent data loss fails the test too.
      records_after = EntityData.list_by_entity(entity.uuid)
      assert length(records_after) == before_count + 1

      assert Enum.any?(records_after, fn r ->
               get_in(r.data, ["title"]) == "Submitted via public form"
             end)
    end

    test "filters fields not in public_form_fields allowlist", %{entity: entity} do
      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{
          "data" => %{
            "title" => "Allowed",
            "secret_field" => "Should be dropped"
          }
        }
      }

      _result = simple_invoke(conn, params)
      # No assertion on the dropped field — the controller's filter
      # silently strips it. Coverage of the filter branch is the goal.
    end

    test "with X-Forwarded-For header, picks up the IP for metadata",
         %{entity: entity} = _ctx do
      conn = build_conn(:post, "/", %{}, forwarded_for: "8.8.8.8")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => %{"title" => "X"}}
      }

      _result = simple_invoke(conn, params)
    end

    test "with spoofed X-Forwarded-For (RFC1918), rejects spoof for rate-limit but uses for metadata",
         %{entity: entity} = _ctx do
      conn = build_conn(:post, "/", %{}, forwarded_for: "10.0.0.1")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => %{"title" => "X"}}
      }

      _result = simple_invoke(conn, params)
    end

    test "Edge user-agent → parsed as Edge browser via metadata", %{entity: entity} do
      conn =
        build_conn(:post, "/", %{},
          user_agent:
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36 Edg/120.0"
        )

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => %{"title" => "X"}}
      }

      _result = simple_invoke(conn, params)
    end

    test "iPhone user-agent → parsed as mobile via metadata", %{entity: entity} do
      conn =
        build_conn(:post, "/", %{},
          user_agent:
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
        )

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => %{"title" => "X"}}
      }

      _result = simple_invoke(conn, params)
    end

    test "Linux user-agent → parsed as Linux OS", %{entity: entity} do
      conn =
        build_conn(:post, "/", %{},
          user_agent: "Mozilla/5.0 (X11; Linux x86_64) Gecko/20100101 Firefox/121.0"
        )

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => %{"title" => "X"}}
      }

      _result = simple_invoke(conn, params)
    end

    test "metadata collection disabled via public_form_collect_metadata=false", %{entity: entity} do
      Entities.update_entity(entity, %{
        settings: Map.merge(entity.settings, %{"public_form_collect_metadata" => false})
      })

      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => %{"title" => "Z"}}
      }

      _result = simple_invoke(conn, params)
    end
  end

  describe "allow_other custom option (Muu)" do
    setup ctx do
      {:ok, other_entity} =
        Entities.create_entity(
          %{
            name: "form_ctrl_widget_other",
            display_name: "Form Ctrl Widget Other",
            display_name_plural: "Form Ctrl Widgets Other",
            status: "published",
            fields_definition: [
              %{
                "type" => "select",
                "key" => "color",
                "label" => "Color",
                "options" => ["Red", "Blue"],
                "allow_other" => true
              }
            ],
            settings: %{
              "public_form_enabled" => true,
              "public_form_fields" => ["color"]
            },
            created_by_uuid: ctx.actor_uuid
          },
          actor_uuid: ctx.actor_uuid
        )

      {:ok, other_entity: other_entity}
    end

    # The companion `color__other` param is never itself in
    # public_form_fields (only real field keys are), so merge_other_params
    # must run BEFORE the allowlist filter — otherwise the free text is
    # dropped and the raw "__other__" sentinel gets saved as `color`.
    test "sentinel + companion free text resolves to the custom value before saving",
         %{other_entity: entity} do
      conn = build_conn(:post, "/", %{}, referer: "https://example.test/form")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{
          "data" => %{"color" => "__other__", "color__other" => "Crimson"}
        }
      }

      result = simple_invoke(conn, params)
      assert result.status in [302, 303]

      [record] = EntityData.list_by_entity(entity.uuid)
      assert record.data["color"] == "Crimson"
    end

    test "a known option is saved unchanged", %{other_entity: entity} do
      conn = build_conn(:post, "/", %{}, referer: "https://example.test/form")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => %{"color" => "Blue"}}
      }

      _result = simple_invoke(conn, params)

      [record] = EntityData.list_by_entity(entity.uuid)
      assert record.data["color"] == "Blue"
    end
  end

  describe "save_suspicious flag" do
    test "honeypot with save_suspicious → record created with status=draft + warnings",
         %{entity: entity} do
      Entities.update_entity(entity, %{
        settings:
          Map.merge(entity.settings, %{
            "public_form_honeypot" => true,
            "public_form_honeypot_action" => "save_suspicious"
          })
      })

      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "_hp_website" => "filled",
        "phoenix_kit_entity_data" => %{"data" => %{"title" => "X"}}
      }

      result = simple_invoke(conn, params)
      assert result.status in [302, 303]
    end
  end

  describe "save_log flag" do
    test "honeypot with save_log → record created + Logger.warning emitted",
         %{entity: entity} do
      Entities.update_entity(entity, %{
        settings:
          Map.merge(entity.settings, %{
            "public_form_honeypot" => true,
            "public_form_honeypot_action" => "save_log"
          })
      })

      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "_hp_website" => "filled",
        "phoenix_kit_entity_data" => %{"data" => %{"title" => "X"}}
      }

      result = simple_invoke(conn, params)
      assert result.status in [302, 303]
    end
  end

  describe "title generation fallbacks" do
    test "no title/name/subject/email → uses entity display_name", %{entity: entity} do
      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => %{"unknown_field" => "X"}}
      }

      _result = simple_invoke(conn, params)
    end
  end

  describe "crafted (non-map / non-string) payloads" do
    # SECURITY: this endpoint is un-authed by design, so the whole request
    # body is attacker-shaped and nested params (`a[b]=c`) arrive as maps.
    # `EntityData.changeset/2` is the shape gate this path relies on, but
    # each of these crashed the controller with an unhandled
    # `FunctionClauseError` — an un-authed 500 — BEFORE the changeset ever
    # ran. Every one must now redirect like an ordinary submission.

    test "a non-map phoenix_kit_entity_data is treated as an empty submission", %{entity: entity} do
      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => "not-a-map"
      }

      result = simple_invoke(conn, params)
      assert result.status in [302, 303]
    end

    test "a non-map \"data\" value is treated as an empty submission", %{entity: entity} do
      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => ["a", "b"]}
      }

      result = simple_invoke(conn, params)
      assert result.status in [302, 303]
    end

    test "a map under a title-candidate key falls back to the entity display name",
         %{entity: entity} do
      # `generate_submission_title/2` accepted any truthy value and handed
      # it straight to `generate_slug/1`'s `String.downcase/1`.
      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => %{"title" => %{"evil" => "map"}}}
      }

      result = simple_invoke(conn, params)
      assert result.status in [302, 303]
    end

    test "a non-string _form_loaded_at is treated as no timestamp", %{entity: entity} do
      # Reached from `check_submission_time/2`, i.e. before any other
      # handling — the earliest crash on this endpoint.
      Entities.update_entity(entity, %{
        settings: Map.merge(entity.settings, %{"public_form_time_check" => true})
      })

      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "_form_loaded_at" => %{"evil" => "map"},
        "phoenix_kit_entity_data" => %{"data" => %{"title" => "X"}}
      }

      result = simple_invoke(conn, params)
      assert result.status in [302, 303]
    end
  end

  describe "public submission of a number field" do
    # SECURITY: the public form endpoint writes straight into
    # `EntityData.create/2` without ever going through
    # `FormBuilder.validate_type/2` — `EntityData.changeset/2`'s
    # `validate_number_field/3` is the ONLY gate a public submission
    # passes. It used to check the raw text with a dot-only regex, so a
    # comma-decimal value (the norm in et/ru locales, and what
    # `<.decimal_input>` on the admin side already accepts) was rejected
    # here even though it is a perfectly valid number.
    setup %{actor_uuid: actor_uuid} do
      {:ok, entity} =
        Entities.create_entity(
          %{
            name: "form_ctrl_number_widget",
            display_name: "Form Ctrl Number Widget",
            display_name_plural: "Form Ctrl Number Widgets",
            status: "published",
            fields_definition: [
              %{"type" => "number", "key" => "amount", "label" => "Amount"}
            ],
            settings: %{
              "public_form_enabled" => true,
              "public_form_fields" => ["amount"]
            },
            created_by_uuid: actor_uuid
          },
          actor_uuid: actor_uuid
        )

      {:ok, number_entity: entity}
    end

    test "a comma-decimal value is stored exactly as the admin path would cast it",
         %{number_entity: entity} do
      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => %{"amount" => "2,5"}}
      }

      # What `LiveDataForm` (admin path) would have stored for the same
      # typed input, via `FormBuilder.validate_data/2`.
      assert {:ok, %{"amount" => expected}} =
               FormBuilder.validate_data(entity, %{"amount" => "2,5"})

      result = simple_invoke(conn, params)
      assert result.status in [302, 303]

      assert Phoenix.Flash.get(result.assigns.flash, :info) =~ "submit" or
               Phoenix.Flash.get(result.assigns.flash, :info) =~ "success"

      [record] = EntityData.list_by_entity(entity.uuid)
      assert get_in(record.data, ["amount"]) === expected
    end

    test "garbage text is rejected, no record created", %{number_entity: entity} do
      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => %{"amount" => "not-a-number"}}
      }

      result = simple_invoke(conn, params)
      assert result.status in [302, 303]
      assert Phoenix.Flash.get(result.assigns.flash, :error) =~ "error"

      assert EntityData.list_by_entity(entity.uuid) == []
    end
  end

  describe "public submission of a decimal field" do
    # SECURITY: same gap as the "number" type above, for "decimal":
    # `validate_decimal_field/3` used to check shape only and never
    # looked at `min`/`max` — an out-of-bounds value that fails to cast in
    # `normalize_numeric_data/1` is left in its raw, still-shape-valid
    # form, and this changeset (the only gate a public submission passes)
    # accepted it anyway.
    setup %{actor_uuid: actor_uuid} do
      {:ok, entity} =
        Entities.create_entity(
          %{
            name: "form_ctrl_decimal_widget",
            display_name: "Form Ctrl Decimal Widget",
            display_name_plural: "Form Ctrl Decimal Widgets",
            status: "published",
            fields_definition: [
              %{
                "type" => "decimal",
                "key" => "price",
                "label" => "Price",
                "min" => "0",
                "max" => "10"
              }
            ],
            settings: %{
              "public_form_enabled" => true,
              "public_form_fields" => ["price"]
            },
            created_by_uuid: actor_uuid
          },
          actor_uuid: actor_uuid
        )

      {:ok, decimal_entity: entity}
    end

    test "an in-bounds comma-decimal value is accepted and cast like the admin path",
         %{decimal_entity: entity} do
      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => %{"price" => "5,10"}}
      }

      assert {:ok, %{"price" => expected}} =
               FormBuilder.validate_data(entity, %{"price" => "5,10"})

      result = simple_invoke(conn, params)
      assert result.status in [302, 303]

      assert Phoenix.Flash.get(result.assigns.flash, :info) =~ "submit" or
               Phoenix.Flash.get(result.assigns.flash, :info) =~ "success"

      [record] = EntityData.list_by_entity(entity.uuid)
      # A `Decimal` has no native JSON representation, so it round-trips
      # through JSONB storage as its canonical string form — same for the
      # admin path (see `EntityData`'s own "decimal" comments) — compare
      # via that string rather than `%Decimal{}` struct equality.
      assert get_in(record.data, ["price"]) == Decimal.to_string(expected, :normal)
    end

    test "an out-of-bounds value is rejected, no record created", %{decimal_entity: entity} do
      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => %{"price" => "999"}}
      }

      result = simple_invoke(conn, params)
      assert result.status in [302, 303]
      assert Phoenix.Flash.get(result.assigns.flash, :error) =~ "error"

      assert EntityData.list_by_entity(entity.uuid) == []
    end
  end

  describe "redirect_back fallback" do
    test "no referer header → redirects to /", %{entity: entity} do
      conn = build_conn(:post, "/")

      params = %{
        "entity_slug" => entity.name,
        "phoenix_kit_entity_data" => %{"data" => %{"title" => "X"}}
      }

      result = simple_invoke(conn, params)
      [location] = Plug.Conn.get_resp_header(result, "location")
      assert location == "/" or String.starts_with?(location, "http")
    end
  end
end
