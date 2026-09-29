defmodule PhoenixKitEntities.Controllers.EntityFormController do
  @moduledoc """
  Controller for handling public entity form submissions.
  """
  use PhoenixKitWeb, :controller
  use Gettext, backend: PhoenixKitEntities.Gettext

  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.FormBuilder

  require Logger

  @browser_patterns [
    {"Edg/", "Edge"},
    {"OPR/", "Opera"},
    {"Opera", "Opera"},
    {"Chrome/", "Chrome"},
    {"Safari/", "Safari"},
    {"Firefox/", "Firefox"},
    {"MSIE", "Internet Explorer"},
    {"Trident/", "Internet Explorer"}
  ]

  @os_patterns [
    {"Windows NT 10", "Windows 10"},
    {"Windows NT 6.3", "Windows 8.1"},
    {"Windows NT 6.2", "Windows 8"},
    {"Windows NT 6.1", "Windows 7"},
    {"Windows", "Windows"},
    {"Mac OS X", "macOS"},
    {"Macintosh", "macOS"},
    {"Linux", "Linux"},
    {"Android", "Android"},
    {"iPhone", "iOS"},
    {"iPad", "iOS"}
  ]

  @device_patterns [
    {"Mobile", "mobile"},
    {"Android", "mobile"},
    {"iPhone", "mobile"},
    {"iPad", "tablet"},
    {"Tablet", "tablet"}
  ]

  # Minimum time in seconds for form submission (time-based validation)
  @min_submission_time 3

  # Rate limit: max submissions per IP
  @rate_limit_max 5
  @rate_limit_window_ms 60_000

  @doc """
  Handles public form submission for entities.
  """
  def submit(conn, %{"entity_slug" => entity_slug} = params) do
    entity = Entities.get_entity_by_name(entity_slug)

    cond do
      is_nil(entity) ->
        conn
        |> put_flash(:error, gettext("Entity not found"))
        |> redirect_back(conn)

      !public_form_enabled?(entity) ->
        conn
        |> put_flash(:error, gettext("Public form is not enabled for this entity"))
        |> redirect_back(conn)

      true ->
        # Run security checks and collect any flags
        security_result = run_security_checks(conn, entity, params)
        handle_security_result(conn, entity, params, security_result)
    end
  end

  defp run_security_checks(conn, entity, params) do
    settings = entity.settings || %{}

    # Collect all security check results
    checks = [
      check_honeypot(settings, params),
      check_submission_time(settings, params),
      check_rate_limit(conn, settings, entity)
    ]

    # Find any triggered checks that require action
    triggered =
      checks
      |> Enum.filter(fn
        {:triggered, _type, _action} -> true
        _ -> false
      end)

    case triggered do
      [] -> :ok
      flags -> {:flagged, flags}
    end
  end

  defp handle_security_result(conn, entity, params, :ok) do
    handle_submission(conn, entity, params, [])
  end

  defp handle_security_result(conn, entity, params, {:flagged, flags}) do
    # Check if any flags require rejection
    reject_flags =
      Enum.filter(flags, fn {:triggered, _type, action} ->
        action in ["reject_silent", "reject_error"]
      end)

    save_flags =
      Enum.filter(flags, fn {:triggered, _type, action} ->
        action in ["save_suspicious", "save_log"]
      end)

    cond do
      # If any flag requires rejection
      not Enum.empty?(reject_flags) ->
        handle_rejection(conn, entity, reject_flags)

      # If flags only require saving with markers
      not Enum.empty?(save_flags) ->
        handle_submission(conn, entity, params, save_flags)

      # Fallback - should not happen
      true ->
        handle_submission(conn, entity, params, [])
    end
  end

  defp handle_rejection(conn, entity, reject_flags) do
    settings = entity.settings || %{}
    debug_mode = Map.get(settings, "public_form_debug_mode", false)

    # Track rejected submission
    increment_form_stats(entity, :rejected, reject_flags)

    # Check if any require error message (reject_error takes precedence)
    has_error =
      Enum.any?(reject_flags, fn {:triggered, _type, action} ->
        action == "reject_error"
      end)

    if has_error do
      # Get the first error type for the message
      {:triggered, error_type, _} = List.first(reject_flags)
      error_message = get_error_message(error_type, debug_mode)

      conn
      |> put_flash(:error, error_message)
      |> redirect_back(conn)
    else
      # Silent rejection - show fake success
      conn
      |> put_flash(:info, get_success_message(entity))
      |> redirect_back(conn)
    end
  end

  # Debug mode error messages (detailed)
  defp get_error_message(:honeypot, true),
    do: gettext("[Debug] Submission rejected: Honeypot field was filled.")

  defp get_error_message(:too_fast, true),
    do:
      gettext(
        "[Debug] Submission rejected: Form was submitted too quickly (less than 3 seconds)."
      )

  defp get_error_message(:rate_limited, true),
    do: gettext("[Debug] Submission rejected: Rate limit exceeded (5 submissions per minute).")

  defp get_error_message(type, true),
    do: gettext("[Debug] Submission rejected: Security check failed (%{type}).", type: type)

  # Normal error messages (generic)
  defp get_error_message(:honeypot, false), do: gettext("There was an error submitting the form.")

  defp get_error_message(:too_fast, false),
    do: gettext("Please take your time filling out the form.")

  defp get_error_message(:rate_limited, false),
    do: gettext("Too many submissions. Please try again later.")

  defp get_error_message(_, false), do: gettext("There was an error submitting the form.")

  defp check_honeypot(settings, params) do
    if Map.get(settings, "public_form_honeypot", false) do
      honeypot_value = Map.get(params, "_hp_website", "")

      if honeypot_value == "" do
        :ok
      else
        action = Map.get(settings, "public_form_honeypot_action", "reject_silent")
        {:triggered, :honeypot, action}
      end
    else
      :ok
    end
  end

  defp check_submission_time(settings, params) do
    if Map.get(settings, "public_form_time_check", false) do
      case get_time_to_submit(params) do
        nil ->
          # No timestamp provided, allow (could be form cached before feature enabled)
          :ok

        seconds when seconds >= @min_submission_time ->
          :ok

        _too_fast ->
          action = Map.get(settings, "public_form_time_check_action", "reject_error")
          {:triggered, :too_fast, action}
      end
    else
      :ok
    end
  end

  # SECURITY: `_form_loaded_at` is a plain body param, so a crafted POST can
  # make it a map (`_form_loaded_at[x]=1`) or a list —
  # `DateTime.from_iso8601/1` only has a binary clause and raised
  # `FunctionClauseError` on anything else. This runs inside the
  # security-check phase, i.e. on every public submission, so it was the
  # earliest un-authed 500 on this endpoint. A non-binary value is treated
  # as "no timestamp provided", exactly like an absent one.
  defp get_time_to_submit(params) do
    case Map.get(params, "_form_loaded_at") do
      loaded_at_str when is_binary(loaded_at_str) ->
        case DateTime.from_iso8601(loaded_at_str) do
          {:ok, loaded_at, _offset} ->
            DateTime.diff(UtilsDate.utc_now(), loaded_at, :second)

          _ ->
            nil
        end

      _absent_or_malformed ->
        nil
    end
  end

  defp check_rate_limit(conn, settings, entity) do
    if Map.get(settings, "public_form_rate_limit", false) do
      ip = get_rate_limit_ip(conn)
      key = "entity_form:#{entity.uuid}:#{ip}"

      # Use the same Backend module used by RateLimiter
      case RateLimiter.Backend.hit(key, @rate_limit_window_ms, @rate_limit_max) do
        {:allow, _count} ->
          :ok

        {:deny, _retry_after} ->
          action = Map.get(settings, "public_form_rate_limit_action", "reject_error")
          {:triggered, :rate_limited, action}
      end
    else
      :ok
    end
  rescue
    # Hammer raises when its backend isn't started yet (test envs, boot
    # races); allow the request. Narrow rescues so genuine bugs surface.
    e in [ArgumentError, RuntimeError, UndefinedFunctionError] ->
      Logger.debug(
        "[EntityFormController] rate-limit check falling open: #{Exception.message(e)}"
      )

      :ok
  end

  defp get_success_message(entity) do
    settings = entity.settings || %{}
    Map.get(settings, "public_form_success_message", gettext("Form submitted successfully!"))
  end

  defp apply_security_flags(metadata, [], _logger) do
    {metadata, "published"}
  end

  defp apply_security_flags(metadata, security_flags, _logger) do
    # Build list of security warnings
    warnings =
      Enum.map(security_flags, fn {:triggered, type, action} ->
        %{"type" => Atom.to_string(type), "action" => action}
      end)

    # Check if any flag marks as suspicious
    is_suspicious =
      Enum.any?(security_flags, fn {:triggered, _type, action} ->
        action == "save_suspicious"
      end)

    # Check if any flag requires logging
    should_log =
      Enum.any?(security_flags, fn {:triggered, _type, action} ->
        action == "save_log"
      end)

    # Log warnings if needed. We bind the Logger module directly so the
    # `Logger.warning/1` macro resolves at compile time — calling
    # `logger.warning(...)` over a runtime-bound variable would fail with
    # `UndefinedFunctionError` because the macro is not exposed as a fn.
    if should_log do
      flag_types = Enum.map(security_flags, fn {:triggered, type, _} -> type end)
      Logger.warning("Form submission with security flags: #{inspect(flag_types)}")
    end

    # Add warnings to metadata
    metadata = Map.put(metadata, "security_warnings", warnings)

    # Set status based on flags
    status = if is_suspicious, do: "draft", else: "published"

    {metadata, status}
  end

  defp handle_submission(conn, entity, params, security_flags) do
    # Extract form data from params
    form_data = extract_form_data(params)

    # Resolve any `allow_other` "Muu" sentinel + companion free-text params
    # into the actual custom value — must happen before filtering by
    # allowed_fields below, since the companion `<key>__other` param is
    # never itself an allowed field and would otherwise be dropped.
    form_data = FormBuilder.merge_other_params(entity.fields_definition || [], form_data)

    # Filter to only include allowed public form fields. Relation fields
    # never take a public value, even when a stale `public_form_fields`
    # lists one: an anonymous form must not be a way to probe which record
    # uuids exist, and the public form renders no picker for them.
    settings = entity.settings || %{}

    relation_keys =
      entity |> PhoenixKitEntities.Relations.relation_fields() |> Enum.map(& &1["key"])

    allowed_fields = Map.get(settings, "public_form_fields", []) -- relation_keys

    filtered_data =
      form_data
      |> Enum.filter(fn {key, _value} -> key in allowed_fields end)
      |> Enum.into(%{})

    # Build entity data params.
    #
    # This form is deliberately unauthenticated, so `current_user` is nil for
    # exactly the flow the feature exists to serve. The key is passed EXPLICITLY
    # as nil in that case: `EntityData.create/2` reads an explicit nil as "this
    # submission has no author" and stores NULL, which is what the column means
    # from core V169 on. Omitting the key would instead trigger the auto-fill and
    # attribute an anonymous submission to the first admin.
    # `:phoenix_kit_current_user` is the key core's `:phoenix_kit_auto_setup`
    # pipeline actually assigns (fetch_phoenix_kit_current_user). Reading
    # `:current_user` — which nothing sets on the conn — made this always nil,
    # so a SIGNED-IN submitter was stored as anonymous and the careful
    # explicit-nil reasoning above never got the chance to matter. Worse on a
    # pre-V169 core, where the column is NOT NULL and an explicit nil turns
    # every submission into a validation failure.
    current_user = conn.assigns[:phoenix_kit_current_user]
    title = generate_submission_title(entity, filtered_data)

    # Capture submission metadata if enabled (default is true)
    collect_metadata = Map.get(settings, "public_form_collect_metadata") != false

    metadata =
      if collect_metadata,
        do: build_submission_metadata(conn, params),
        else: %{"source" => "public_form"}

    # Add security flags to metadata if any were triggered
    {metadata, status} = apply_security_flags(metadata, security_flags, Logger)

    entity_data_params = %{
      "entity_uuid" => entity.uuid,
      "title" => title,
      "slug" => generate_slug(title),
      "status" => status,
      "data" => filtered_data,
      "metadata" => metadata,
      "created_by_uuid" => current_user && current_user.uuid
    }

    # Pass the actor explicitly, nil included: an anonymous submission has no
    # actor, and the activity log's fallback would otherwise file it under the
    # creator the auto-fill chose.
    case EntityData.create(entity_data_params, actor_uuid: current_user && current_user.uuid) do
      {:ok, _data_record} ->
        # Track successful submission
        increment_form_stats(entity, :submitted, security_flags)

        success_message =
          Map.get(
            settings,
            "public_form_success_message",
            gettext("Form submitted successfully!")
          )

        conn
        |> put_flash(:info, success_message)
        |> redirect_back(conn)

      {:error, _changeset} ->
        conn
        |> put_flash(:error, gettext("There was an error submitting the form. Please try again."))
        |> redirect_back(conn)
    end
  end

  # SECURITY: this endpoint is un-authed by design (see the moduledoc), so
  # the request body is entirely attacker-shaped — `phoenix_kit_entity_data`
  # and its `"data"` value are both whatever was posted, not necessarily
  # maps. `get_in(params, ["phoenix_kit_entity_data", "data"])` raised
  # `FunctionClauseError` (Access has no clause for a binary) for
  # `phoenix_kit_entity_data=x`, and a non-map `"data"` got through it only
  # to hit `FormBuilder.merge_other_params/2`'s `when is_map(params)` guard
  # — an unmatched-clause crash. Either way an unauthenticated request
  # turned into a 500 before `EntityData.changeset/2` (the shape gate this
  # path relies on) ever ran. Both shapes now degrade to "no fields
  # submitted", the same result as an empty POST — same contract as
  # `LiveDataForm.extract_data_params/1` on the LiveView side.
  defp extract_form_data(%{"phoenix_kit_entity_data" => %{"data" => %{} = data}}), do: data
  defp extract_form_data(_params), do: %{}

  defp public_form_enabled?(entity) do
    settings = entity.settings || %{}
    enabled = Map.get(settings, "public_form_enabled", false)
    fields = Map.get(settings, "public_form_fields", [])
    # Form is only truly enabled if it's enabled AND has at least one field selected
    enabled && not Enum.empty?(fields)
  end

  # SECURITY: the candidate keys are ordinary field keys — nothing forces
  # their submitted values to be strings, and a nested param
  # (`data[name][x]=1`) arrives as a map. The old `if value && value != ""`
  # accepted it, and `generate_slug/1` immediately fed it to
  # `String.downcase/1`, which has no clause for a map (or a list, or a
  # number) — an unauthenticated 500, again before `EntityData.changeset/2`
  # could reject anything. Only a non-empty binary is a usable title;
  # anything else falls through to the next candidate and ultimately to
  # `entity.display_name`.
  defp generate_submission_title(entity, data) do
    # Try to use a meaningful field value as title, or use entity display name
    title_candidates = ["name", "title", "subject", "email"]

    Enum.find_value(title_candidates, fn field ->
      case Map.get(data, field) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end) || entity.display_name
  end

  defp generate_slug(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
    |> Kernel.<>("-#{:rand.uniform(9999)}")
  end

  # Cap stored header values so a malicious 50KB user-agent string
  # doesn't bloat the JSONB column. Same cap on referer; truncated rather
  # than dropped so analytics still see something but storage is bounded.
  @metadata_string_cap 255

  defp build_submission_metadata(conn, params) do
    user_agent = get_req_header(conn, "user-agent") |> List.first() || ""
    referer = get_req_header(conn, "referer") |> List.first()
    submitted_at = UtilsDate.utc_now()

    # Get form timing data. Capped like the header values below — same
    # untrusted-input class — via `cap_metadata_param/1`, whose binary-or-nil
    # clauses also keep a crafted non-string (a nested `_form_loaded_at[x]`
    # param arrives as a map) out of the stored JSONB entirely.
    form_loaded_at = params |> Map.get("_form_loaded_at") |> cap_metadata_param()
    time_to_submit = get_time_to_submit(params)

    capped_user_agent = cap_string(user_agent, @metadata_string_cap)

    %{
      "source" => "public_form",
      "ip_address" => get_client_ip(conn),
      "user_agent" => capped_user_agent,
      "browser" => parse_browser(capped_user_agent),
      "os" => parse_os(capped_user_agent),
      "device" => parse_device(capped_user_agent),
      "referer" => cap_string(referer, @metadata_string_cap),
      "form_loaded_at" => form_loaded_at,
      "submitted_at" => DateTime.to_iso8601(submitted_at),
      "time_to_submit_seconds" => time_to_submit
    }
  end

  defp cap_string(nil, _cap), do: nil

  defp cap_string(value, cap) when is_binary(value) do
    if byte_size(value) > cap, do: String.slice(value, 0, cap), else: value
  end

  # `cap_string/2` deliberately has no non-binary clause — the header values
  # it guards are always strings, and a surprise there should crash rather
  # than store silently. Body params have no such guarantee, so they get
  # this binary-or-nil wrapper instead.
  defp cap_metadata_param(value) when is_binary(value),
    do: cap_string(value, @metadata_string_cap)

  defp cap_metadata_param(_value), do: nil

  # Returns the client IP for storage in submission metadata.
  # Best-effort; falls back to remote_ip when the forwarded value is
  # missing or malformed. Distinct from `get_rate_limit_ip/1` which
  # rejects spoofed/private values entirely so they can't multiply
  # rate-limit buckets.
  defp get_client_ip(conn) do
    case parse_forwarded_for(conn) do
      nil -> remote_ip_string(conn)
      ip -> ip
    end
  end

  # Returns an IP suitable for use as a rate-limit key. RFC1918 / loopback
  # / link-local / non-IPv4 values from `X-Forwarded-For` are rejected
  # back to the conn's `remote_ip` so an attacker can't spoof
  # `X-Forwarded-For: 1.2.3.4` to get their own per-fake-IP bucket and
  # bypass the per-IP limit. The conn's `remote_ip` is set by the
  # endpoint and is the actual TCP peer.
  defp get_rate_limit_ip(conn) do
    case parse_forwarded_for(conn) do
      nil -> remote_ip_string(conn)
      ip -> if rate_limit_safe_ip?(ip), do: ip, else: remote_ip_string(conn)
    end
  end

  defp parse_forwarded_for(conn) do
    case get_req_header(conn, "x-forwarded-for") |> List.first() do
      nil ->
        nil

      header ->
        header
        |> String.split(",")
        |> List.first()
        |> String.trim()
        |> case do
          "" -> nil
          ip -> ip
        end
    end
  end

  defp remote_ip_string(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  # Strict IPv4 dotted-quad with each octet 0-255, AND rejects RFC1918
  # ranges, loopback, link-local, and the unspecified address — those
  # would let an internal/forwarded value fake a public IP bucket.
  defp rate_limit_safe_ip?(ip) when is_binary(ip) do
    Regex.match?(~r/^(?:\d{1,3}\.){3}\d{1,3}$/, ip) and not private_or_local_ip?(ip)
  end

  # Integer.parse/1 returns `{int, rest}` or `:error` instead of raising,
  # so we can drop the rescue clause and pin the failure shape explicitly.
  # Any non-numeric octet (e.g. "abc.def.ghi.jkl" slipping past the regex,
  # or values overflowing int) collapses to the safe-by-default `true`.
  defp private_or_local_ip?(ip) do
    with [a, b, _, _] <- String.split(ip, "."),
         {a_int, ""} <- Integer.parse(a),
         {b_int, ""} <- Integer.parse(b) do
      unsafe_octets?(a_int, b_int)
    else
      _ -> true
    end
  end

  # RFC1918 + loopback + link-local + multicast/reserved (224+).
  defp unsafe_octets?(0, _), do: true
  defp unsafe_octets?(10, _), do: true
  defp unsafe_octets?(127, _), do: true
  defp unsafe_octets?(169, 254), do: true
  defp unsafe_octets?(172, b) when b in 16..31, do: true
  defp unsafe_octets?(192, 168), do: true
  defp unsafe_octets?(a, _) when a >= 224, do: true
  defp unsafe_octets?(_, _), do: false

  defp parse_browser(user_agent) do
    Enum.find_value(@browser_patterns, "Unknown", fn {pattern, name} ->
      if String.contains?(user_agent, pattern), do: name
    end)
  end

  defp parse_os(user_agent) do
    Enum.find_value(@os_patterns, "Unknown", fn {pattern, name} ->
      if String.contains?(user_agent, pattern), do: name
    end)
  end

  defp parse_device(user_agent) do
    Enum.find_value(@device_patterns, "desktop", fn {pattern, type} ->
      if String.contains?(user_agent, pattern), do: type
    end)
  end

  # Honor the Referer header only when it points back at the same host
  # we're serving from. The header is attacker-controllable (any page
  # can link/post here with a crafted Referer), so passing it raw into
  # `redirect(external: …)` was an open-redirect surface — phishing
  # bait that bounces through this app's domain. We parse it, require
  # an http/https scheme + host match against `conn.host`, and emit a
  # path-only relative redirect with the host stripped. Anything that
  # doesn't pass falls back to "/".
  defp redirect_back(conn, _fallback_conn) do
    case get_req_header(conn, "referer") |> List.first() do
      nil -> redirect(conn, to: "/")
      referer -> redirect(conn, to: safe_referer_path(referer, conn.host) || "/")
    end
  end

  defp safe_referer_path(referer, expected_host) when is_binary(referer) do
    case URI.parse(referer) do
      %URI{scheme: scheme, host: ^expected_host, path: path, query: query}
      when scheme in ["http", "https"] and is_binary(path) ->
        # Reject protocol-relative paths ("//evil.com/foo" parses out as
        # a `path` here). `redirect(conn, to: "//…")` would otherwise
        # raise `ArgumentError` via Phoenix's own local-URL guard — not
        # an open redirect, but a 500 we'd rather convert to the "/" fallback.
        cond do
          String.starts_with?(path, "//") -> nil
          not String.starts_with?(path, "/") -> nil
          is_binary(query) -> path <> "?" <> query
          true -> path
        end

      _ ->
        nil
    end
  end

  defp safe_referer_path(_, _), do: nil

  # Form statistics tracking
  # Stats are stored in entity.settings under "public_form_stats".
  # Supervised under PhoenixKit.TaskSupervisor — fire-and-forget after
  # the response is sent. The narrow rescue lets transient `Ecto.StaleEntryError`
  # from concurrent submissions degrade silently (next submission re-counts);
  # everything else logs.
  defp increment_form_stats(entity, event_type, security_flags) do
    Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, fn ->
      try do
        current_settings = entity.settings || %{}
        current_stats = Map.get(current_settings, "public_form_stats", %{})

        # Initialize stats structure if needed
        updated_stats =
          current_stats
          |> Map.update("total_submissions", 1, &(&1 + 1))
          |> update_event_count(event_type)
          |> update_security_stats(security_flags)
          |> Map.put("last_submission_at", UtilsDate.utc_now() |> DateTime.to_iso8601())

        updated_settings = Map.put(current_settings, "public_form_stats", updated_stats)

        # Update entity settings directly via Repo
        Entities.update_entity(entity, %{"settings" => updated_settings})
      rescue
        Ecto.StaleEntryError ->
          # Concurrent submission updated stats first — next one re-counts.
          :ok

        e ->
          Logger.warning(
            "[EntityFormController] form-stats update failed for entity #{entity.uuid}: " <>
              Exception.message(e)
          )

          {:error, e}
      end
    end)
  end

  defp update_event_count(stats, :submitted) do
    Map.update(stats, "successful_submissions", 1, &(&1 + 1))
  end

  defp update_event_count(stats, :rejected) do
    Map.update(stats, "rejected_submissions", 1, &(&1 + 1))
  end

  defp update_security_stats(stats, []), do: stats

  defp update_security_stats(stats, security_flags) do
    Enum.reduce(security_flags, stats, fn {:triggered, type, _action}, acc ->
      key = "#{type}_triggers"
      Map.update(acc, key, 1, &(&1 + 1))
    end)
  end
end
