defmodule RelayDev.Acceptance do
  @moduledoc """
  The region acceptance suite (OP-58 (7), OP-93, OP-75): black-box steps against one Relay base URL that time what they measure and return a report. It runs from the `region-acceptance` workflow against a region and every night against the compose installation (`mix relay.acceptance`).

    * `isolation`: a request without credentials answers 401, an unknown identifier 404, and with a second tenant's credentials the first tenant's event answers 404 (TN-16, TN-15).
    * `shadow_send`: an event in `shadow` send mode is accepted and every delivery reaches a final state; the time is end to end (OP-52).
    * `pool_saturation` (with Toxiproxy): with added latency on the database proxy a burst of sends is answered only with 202 or 503 with `Retry-After`, and every accepted event has its deliveries (OP-49, OP-88).
    * `failover`: sends keep coming while the failover command runs (a Postgres restart on compose, a real failover in a region); every accepted event is still readable afterwards (loss 0, OP-28, OP-76); the time is from the command to the first accepted send after it.
    * `archive_restore`: the archive restore command, timed; skipped while none is given (OP-84).
    * `kill_switch`: a workflow kill switch with a two minute TTL, then a send of that workflow; the time is from the engage to the delivery paused by the kill switch, at most 60 seconds (TN-39, OP-47).

  A step answers `passed`, `failed` or `skipped` with its time in milliseconds and a detail that carries no credential.
  """

  @final ~w(sent delivered unknown failed skipped expired cancelled)

  @type config :: %{
          required(:base_url) => String.t(),
          required(:public_url) => String.t(),
          required(:headers) => [{String.t(), String.t()}],
          required(:auth) => auth(),
          required(:other) => auth() | nil,
          required(:workflow) => String.t(),
          required(:recipient) => String.t(),
          required(:failover_command) => String.t() | nil,
          required(:restore_command) => String.t() | nil,
          required(:toxiproxy) => String.t() | nil
        }
  @type auth :: %{token: String.t(), proof: (String.t(), String.t() -> String.t())}
  @type step :: %{name: String.t(), status: String.t(), ms: non_neg_integer(), detail: map()}

  # OP-93
  # OP-58
  @doc "Runs every step in order and returns the report."
  @spec run(config()) :: %{passed: boolean(), steps: [step()]}
  def run(config) do
    steps =
      for {name, fun} <- [
            isolation: &isolation/1,
            shadow_send: &shadow_send/1,
            pool_saturation: &pool_saturation/1,
            failover: &failover/1,
            archive_restore: &archive_restore/1,
            kill_switch: &kill_switch/1
          ] do
        timed(Atom.to_string(name), fn -> fun.(config) end)
      end

    %{passed: Enum.all?(steps, &(&1.status != "failed")), steps: steps}
  end

  # OP-93
  @doc "An Ed25519 DPoP signer of a 32-byte seed: a function of the method and the URL of one request, for the token `token`."
  @spec ed25519_proof(binary(), String.t()) :: (String.t(), String.t() -> String.t())
  def ed25519_proof(seed, token) when byte_size(seed) == 32 do
    {public, _private} = :crypto.generate_key(:eddsa, :ed25519, seed)
    jwk = %{"kty" => "OKP", "crv" => "Ed25519", "x" => b64(public)}

    fn method, url ->
      header = %{"alg" => "EdDSA", "typ" => "dpop+jwt", "jwk" => jwk}

      claims = %{
        "htm" => method,
        "htu" => url,
        "ath" => b64(:crypto.hash(:sha256, token)),
        "iat" => System.os_time(:second),
        "jti" => b64(:crypto.strong_rand_bytes(16))
      }

      input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
      input <> "." <> b64(:crypto.sign(:eddsa, :none, input, [seed, :ed25519]))
    end
  end

  defp timed(name, fun) do
    started = System.monotonic_time(:millisecond)

    {status, detail} =
      try do
        fun.()
      rescue
        exception -> {:failed, %{error: Exception.message(exception)}}
      end

    elapsed = Map.get(detail, :ms, System.monotonic_time(:millisecond) - started)
    %{name: name, status: Atom.to_string(status), ms: elapsed, detail: Map.delete(detail, :ms)}
  end

  defp isolation(config) do
    unknown = "evt_" <> String.duplicate("0", 26)
    anonymous = request(config, nil, :get, "/v1/events/" <> unknown)
    missing = request(config, config.auth, :get, "/v1/events/" <> unknown)
    checks = %{anonymous: anonymous.status == 401, unknown_id: missing.status == 404}

    checks =
      case config.other do
        nil ->
          checks

        other ->
          {202, accepted} = send_event(config, %{})
          foreign = request(config, other, :get, "/v1/events/" <> accepted["id"])
          Map.put(checks, :other_tenant, foreign.status == 404)
      end

    status = if Enum.all?(Map.values(checks)), do: :passed, else: :failed
    note = if config.other, do: nil, else: "no second tenant credentials; no cross-tenant read"
    {status, Map.merge(checks, %{note: note})}
  end

  defp shadow_send(config) do
    started = System.monotonic_time(:millisecond)

    case send_event(config, %{"send_mode" => "shadow"}) do
      {202, accepted} ->
        statuses = wait_final(config, accepted, 120_000)
        final? = statuses != [] and Enum.all?(statuses, &(&1 in @final))
        ms = System.monotonic_time(:millisecond) - started
        {if(final?, do: :passed, else: :failed), %{ms: ms, statuses: statuses}}

      {status, body} ->
        {:failed, %{status: status, code: body["code"]}}
    end
  end

  defp pool_saturation(%{toxiproxy: nil}), do: {:skipped, %{note: "no Toxiproxy"}}

  defp pool_saturation(config) do
    toxic = %{
      name: "saturate",
      type: "latency",
      stream: "downstream",
      attributes: %{latency: 3_000}
    }

    Req.post!(config.toxiproxy <> "/proxies/postgres/toxics", json: toxic, retry: false)

    responses =
      try do
        1..40
        |> Task.async_stream(fn _ -> send_raw(config, %{}) end,
          max_concurrency: 40,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, response} -> response end)
      after
        Req.delete!(config.toxiproxy <> "/proxies/postgres/toxics/saturate", retry: false)
      end

    counts = Enum.frequencies_by(responses, &Integer.to_string(&1.status))
    admitted? = Enum.all?(responses, &(&1.status == 202 or shed?(&1)))
    accepted = for %{status: 202, body: body} <- responses, do: body
    lost = Enum.reject(accepted, &enqueued?(config, &1))
    status = if admitted? and lost == [], do: :passed, else: :failed
    {status, %{statuses: counts, accepted_not_enqueued: length(lost)}}
  end

  defp shed?(%{status: 503} = response),
    do: Req.Response.get_header(response, "retry-after") != []

  defp shed?(_response), do: false

  defp failover(%{failover_command: nil}),
    do: {:skipped, %{note: "no failover command; set ACCEPTANCE_FAILOVER_COMMAND"}}

  defp failover(config) do
    sender = Task.async(fn -> keep_sending(config, []) end)
    Process.sleep(3_000)
    started = System.monotonic_time(:millisecond)

    {_output, exit_status} =
      System.cmd("sh", ["-c", config.failover_command], stderr_to_stdout: true)

    Process.sleep(30_000)
    send(sender.pid, :stop)
    sent = Task.await(sender, 120_000)

    accepted = for {at, 202, body} <- sent, do: {at, body}
    after_command = for {at, _body} <- accepted, at > started, do: at
    recovered = if after_command == [], do: nil, else: Enum.min(after_command) - started
    lost = for {_at, body} <- accepted, not readable?(config, body), do: body["id"]

    status = if exit_status == 0 and lost == [] and recovered != nil, do: :passed, else: :failed

    {status,
     %{
       command_exit: exit_status,
       accepted: length(accepted),
       refused: length(sent) - length(accepted),
       lost: length(lost),
       recovery_ms: recovered
     }}
  end

  defp keep_sending(config, acc) do
    receive do
      :stop -> Enum.reverse(acc)
    after
      200 ->
        response = send_raw(config, %{})
        at = System.monotonic_time(:millisecond)
        keep_sending(config, [{at, response.status, response.body} | acc])
    end
  end

  defp archive_restore(%{restore_command: nil}),
    do: {:skipped, %{note: "no archive restore command; set ACCEPTANCE_RESTORE_COMMAND"}}

  defp archive_restore(config) do
    {_output, exit_status} =
      System.cmd("sh", ["-c", config.restore_command], stderr_to_stdout: true)

    {if(exit_status == 0, do: :passed, else: :failed), %{command_exit: exit_status}}
  end

  defp kill_switch(config) do
    engage = %{
      "scope_kind" => "workflow",
      "scope_ref" => config.workflow,
      "reason" => "region acceptance kill switch drill",
      "ttl" => "PT2M"
    }

    started = System.monotonic_time(:millisecond)

    case request(config, config.auth, :post, "/v1/kill_switches", engage) do
      %{status: 201, body: switch} ->
        engaged_ms = System.monotonic_time(:millisecond) - started
        {202, accepted} = send_event(config, %{})
        paused? = wait_paused(config, accepted, started + 60_000)
        ms = System.monotonic_time(:millisecond) - started
        status = if paused? and ms < 60_000, do: :passed, else: :failed
        {status, %{ms: ms, engage_ms: engaged_ms, kill_switch: switch["id"]}}

      response ->
        {:failed, %{status: response.status, code: code(response.body)}}
    end
  end

  defp wait_paused(config, accepted, deadline) do
    paused? =
      Enum.any?(deliveries(config, accepted), fn delivery ->
        is_binary(delivery["rule_id"]) and String.starts_with?(delivery["rule_id"], "killswitch")
      end)

    cond do
      paused? ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(250)
        wait_paused(config, accepted, deadline)
    end
  end

  defp wait_final(config, accepted, timeout_ms),
    do: until_final(config, accepted, System.monotonic_time(:millisecond) + timeout_ms)

  defp until_final(config, accepted, deadline) do
    statuses = for delivery <- deliveries(config, accepted), do: delivery["status"]

    cond do
      statuses != [] and Enum.all?(statuses, &(&1 in @final)) ->
        statuses

      System.monotonic_time(:millisecond) > deadline ->
        statuses

      true ->
        Process.sleep(500)
        until_final(config, accepted, deadline)
    end
  end

  defp deliveries(config, accepted) do
    for %{"notification_id" => id} <- accepted["notifications"] || [],
        response = request(config, config.auth, :get, "/v1/notifications/#{id}/deliveries"),
        response.status == 200,
        delivery <- response.body["data"] || [],
        do: delivery
  end

  defp readable?(config, %{"id" => id}),
    do: request(config, config.auth, :get, "/v1/events/" <> id).status == 200

  defp readable?(_config, _body), do: false

  defp enqueued?(config, accepted),
    do: readable?(config, accepted) and deliveries(config, accepted) != []

  defp send_event(config, extra) do
    response = send_raw(config, extra)
    {response.status, response.body}
  end

  defp send_raw(config, extra) do
    event =
      Map.merge(
        %{
          "workflow" => config.workflow,
          "to" => [config.recipient],
          "data" => %{"first_name" => "Acceptance"}
        },
        extra
      )

    request(config, config.auth, :post, "/v1/events", event)
  end

  defp request(config, auth, method, path, body \\ nil) do
    verb = method |> Atom.to_string() |> String.upcase()
    public = config.public_url <> path

    credentials =
      case auth do
        nil ->
          []

        %{token: token, proof: proof} ->
          [{"authorization", "DPoP " <> token}, {"dpop", proof.(verb, public)}]
      end

    key =
      if method == :get,
        do: [],
        else: [{"idempotency-key", "acceptance-" <> b64(:crypto.strong_rand_bytes(12))}]

    options = [
      method: method,
      url: config.base_url <> path,
      headers: config.headers ++ credentials ++ key,
      retry: false,
      receive_timeout: 30_000
    ]

    options = if body, do: Keyword.put(options, :json, body), else: options

    case Req.request(options) do
      {:ok, response} ->
        response

      {:error, exception} ->
        %Req.Response{status: 0, body: %{"error" => Exception.message(exception)}}
    end
  end

  defp code(%{"code" => code}), do: code
  defp code(_body), do: nil

  defp b64(binary), do: Base.url_encode64(binary, padding: false)
end
