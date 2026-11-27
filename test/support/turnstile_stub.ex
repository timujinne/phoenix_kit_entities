defmodule PhoenixKitEntities.Test.TurnstileStub do
  @moduledoc """
  Cloudflare for the Turnstile tests: nothing leaves the machine.

  Core sends its siteverify request through the plug set as
  `config :phoenix_kit, :turnstile_req_options, plug: ...`. `install/0` sets a
  plug that plays Cloudflare and reports every request to the calling test as
  `{:siteverify, form}`; the token picks the verdict:

    * `"good-token"` — accepted;
    * `"cloudflare-is-down"` — no verdict (HTTP 503);
    * anything else — refused (`invalid-input-response`).

  A request carrying another secret than `secret/0` is answered
  `invalid-input-secret`, as Cloudflare would.
  """
  import ExUnit.Assertions

  alias PhoenixKit.Integrations

  @secret "0x4AAAA-test-secret"

  def secret, do: @secret

  @doc "Routes core's siteverify calls to the stub for the calling test, restoring the old value on exit."
  def install do
    test_pid = self()
    previous = Application.fetch_env(:phoenix_kit, :turnstile_req_options)
    Application.put_env(:phoenix_kit, :turnstile_req_options, plug: plug(test_pid))

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :turnstile_req_options, value)
        :error -> Application.delete_env(:phoenix_kit, :turnstile_req_options)
      end
    end)

    :ok
  end

  @doc """
  A website connection the way an admin sets one up: added, given keys,
  checked (the check is what marks it `connected`). Needs `install/0` first.
  """
  def verified_connection!(name, site_key) do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("cloudflare_turnstile", name)
    {:ok, _} = Integrations.save_setup(uuid, %{"site_key" => site_key, "secret_key" => @secret})

    :ok = verdict = Integrations.validate_connection(uuid)
    :ok = Integrations.record_validation(uuid, verdict)

    # The key check made one request of its own.
    assert_received {:siteverify, %{"response" => "phoenix-kit-key-check"}}
    uuid
  end

  defp plug(test_pid) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      form = URI.decode_query(body)
      send(test_pid, {:siteverify, form})

      cond do
        form["response"] == "cloudflare-is-down" ->
          Plug.Conn.send_resp(conn, 503, "unavailable")

        form["secret"] != @secret ->
          Req.Test.json(conn, %{"success" => false, "error-codes" => ["invalid-input-secret"]})

        form["response"] == "good-token" ->
          Req.Test.json(conn, %{"success" => true})

        true ->
          Req.Test.json(conn, %{"success" => false, "error-codes" => ["invalid-input-response"]})
      end
    end
  end
end
