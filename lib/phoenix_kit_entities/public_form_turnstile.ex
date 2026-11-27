defmodule PhoenixKitEntities.PublicFormTurnstile do
  @moduledoc """
  Cloudflare Turnstile for an entity's public form, built on core's website
  integrations (`PhoenixKit.Integrations.Turnstile`, core 3.7.0+).

  Per entity, in `settings`:

    * `"public_form_turnstile"` — the switch (default off).
    * `"public_form_turnstile_connection"` — the UUID of a verified
      Cloudflare Turnstile connection (Settings → Integrations).
    * `"public_form_turnstile_action"` — what a failed check does, one of
      the security actions every other check uses (default `"reject_error"`).

  The connection belongs to the entity, so this is independent of the
  Authorization page's switch, which only protects core's own auth forms.

  ## Policy

    * A token Cloudflare refuses: the check is triggered and the configured
      action applies.
    * No token: the same, except that `reject_silent` becomes `reject_error`.
      A visitor without a token is overwhelmingly a real one whose widget did
      not start (no JavaScript, a blocked script, the host bundle missing), and
      a fake success would swallow their message.
    * Cloudflare gives no verdict (`:unavailable`): fail closed, with a
      "try again in a few minutes" message — the action applies as well, except
      that `reject_silent` becomes `reject_error`, because a silent fake
      success would swallow a real visitor's message over an outage that is not
      theirs.
    * The switch is on but the connection is missing, was removed, or no
      longer verifies (`:not_configured`): `verify/3` answers `:unchecked`, and
      the form is **not** checked: the controller lets the request through,
      logs an error naming the entity, counts it in the form statistics
      (`turnstile_unchecked_triggers`) and flags the stored submission
      (`security_warnings`, action `none`). This is what core does for its
      auth forms: the widget is hidden in that state, so refusing every submit
      would lock the form for everyone, with nothing on the page to fix. The
      builder shows a warning while the option is on and the connection is
      not usable.

  The switch itself is `true` (or the string `"true"`, as a hand-edited or
  imported value would read); anything else is off.
  """

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Turnstile, as: Cloudflare

  @type status :: :off | :ready | :no_connections | :no_selection | :stale_selection

  @doc "Whether the entity's settings turn Turnstile on."
  @spec enabled?(map() | nil) :: boolean()
  def enabled?(settings), do: get(settings, "public_form_turnstile") in [true, "true"]

  @doc "The selected connection UUID, or nil."
  @spec connection(map() | nil) :: String.t() | nil
  def connection(settings) do
    case get(settings, "public_form_turnstile_connection") do
      uuid when is_binary(uuid) and uuid != "" -> canonical(uuid)
      _ -> nil
    end
  end

  # Core resolves a UUID however it is cased; compare it the same way.
  defp canonical(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, cast} -> cast
      :error -> uuid
    end
  end

  @doc "Verified website Turnstile connections, as `{uuid, name}`."
  @spec choices() :: [{String.t(), String.t()}]
  def choices, do: Integrations.connected_choices(:turnstile, :system)

  @doc "The name of the form field the widget fills."
  @spec response_field() :: String.t()
  def response_field, do: Cloudflare.response_field()

  @doc """
  The public site key the form's widget renders with, or nil when the option
  is off or its connection cannot verify (the widget is then hidden).
  """
  @spec site_key(map() | nil) :: String.t() | nil
  def site_key(settings) do
    with true <- enabled?(settings),
         uuid when is_binary(uuid) <- connection(settings) do
      Cloudflare.site_key(uuid)
    else
      _ -> nil
    end
  end

  @doc """
  What the builder should tell the admin, given the connections `choices/0`
  returned: `:off`, `:ready`, or why a switched-on form is not protected.
  """
  @spec status(map() | nil, [{String.t(), String.t()}]) :: status()
  def status(settings, choices) do
    cond do
      not enabled?(settings) -> :off
      choices == [] -> :no_connections
      is_nil(connection(settings)) -> :no_selection
      Enum.any?(choices, fn {uuid, _name} -> uuid == connection(settings) end) -> :ready
      true -> :stale_selection
    end
  end

  @doc """
  Checks the token a submit carried. `:unchecked` means the option is on but
  its connection cannot verify (see the moduledoc), so nothing was checked.
  """
  @spec verify(map() | nil, term(), String.t() | nil) ::
          :ok | :unchecked | {:error, :missing | :rejected | :unavailable}
  def verify(settings, token, ip_address) do
    with true <- enabled?(settings),
         uuid when is_binary(uuid) <- connection(settings) do
      case Cloudflare.verify(uuid, token, ip_address) do
        {:error, :not_configured} -> :unchecked
        verdict -> verdict
      end
    else
      false -> :ok
      nil -> :unchecked
    end
  end

  defp get(settings, key) when is_map(settings), do: Map.get(settings, key)
  defp get(_settings, _key), do: nil
end
