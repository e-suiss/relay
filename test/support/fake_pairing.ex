defmodule RelayTest.FakePairing do
  @moduledoc """
  The pairing side of the fake Access (E-101), served as a `Req` plug in front of `RelayTest.FakeAccess` (`Relay.Access.Pairing.run/2` with `http: [plug: {RelayTest.FakePairing, agent}]`): it publishes the Suiss configuration with the pairing routes and answers `pairing_challenges`, `pairing` and `platform_streams`; every other path goes to `RelayTest.FakeAccess`. Each route takes only `Authorization: Bearer` with Relay's RFC 7523 client assertion, as Access checks it.

  Every realm of the tenant snapshot gets a fresh challenge for the service key `access-service` (its RFC 7638 thumbprint as `kid`, the challenge as `instance_create` nonce, the challenge followed by `0x01` as `party_register` nonce, ten minutes of validity) until a pairing answers it with `ais` `placeholder-ais` (and `register_ais` `placeholder-register-ais`); from then on the realm is `paired`. The state (`start!/1`) can refuse realms, break a challenge (`tamper:` `:kid`, `:nonce`, `:register_nonce` or `:validity`), queue failed answers of the challenge route (`challenge_failures:`, a list of `{status, code}`) and hold the streams. The calling test process receives `{:fake_pairing, :challenges, tenant}`, `{:fake_pairing, :pairing, tenant, body}`, `{:fake_pairing, :streams}`, `{:fake_pairing, :stream, id}` and `{:fake_pairing, :open_stream, body}`.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Access, RelayTest.FakeAccess],
    exports: []

  @behaviour Plug

  import Plug.Conn

  alias RelayTest.FakeAccess

  @base "/access/v1"
  @receiver "https://localhost/v1/access/events"
  @push "urn:ietf:rfc:8935"

  @doc "Relay's event receiver, as the default configuration names it."
  @spec receiver() :: String.t()
  def receiver, do: @receiver

  @doc "Starts the state: `refused:` realms, `tamper:`, `challenge_failures:` and `streams:`."
  @spec start!(keyword()) :: pid()
  def start!(opts \\ []) do
    state = %{
      paired: %{},
      refused: MapSet.new(Keyword.get(opts, :refused, [])),
      tamper: Keyword.get(opts, :tamper),
      challenge_failures: Keyword.get(opts, :challenge_failures, []),
      issued: %{},
      streams: Keyword.get(opts, :streams, [])
    }

    {:ok, agent} = Agent.start_link(fn -> state end)
    agent
  end

  @doc "Changes the state."
  @spec update(pid(), (map() -> map())) :: :ok
  def update(agent, fun), do: Agent.update(agent, fun)

  @doc "Reads the state."
  @spec state(pid()) :: map()
  def state(agent), do: Agent.get(agent, & &1)

  @doc "A stream as `platform_streams` shows it, pushing to Relay's receiver."
  @spec stream(String.t(), String.t()) :: map()
  def stream(id, status) do
    %{
      "stream_id" => id,
      "iss" => FakeAccess.issuer(),
      "aud" => Relay.Access.client_id(),
      "delivery" => %{"method" => @push, "endpoint_url" => @receiver},
      "events_supported" => ["urn:suiss:access:event:tenant.created"],
      "status" => status
    }
  end

  @doc "The RFC 7638 thumbprint of the service key."
  @spec kid() :: binary()
  def kid do
    {:ok, key} = Relay.Keys.public_key(:ed25519, "access-service")
    Relay.Access.ServiceKey.thumbprint(key)
  end

  @impl Plug
  def init(agent), do: agent

  @impl Plug
  def call(conn, agent) do
    case {conn.method, conn.request_path} do
      {"GET", "/.well-known/suiss-configuration"} -> json(conn, 200, suiss())
      {_method, @base <> "/" <> rest} -> routed(conn, String.split(rest, "/"), agent)
      _other -> FakeAccess.call(conn, [])
    end
  end

  defp suiss do
    base = FakeAccess.issuer() <> @base

    endpoints = %{
      "tenant_snapshot" => base <> "/tenants/{tenant}/snapshot",
      "pairing_challenges" => base <> "/tenants/{tenant}/pairing/challenges",
      "pairing" => base <> "/tenants/{tenant}/pairing",
      "platform_streams" => base <> "/platform/streams"
    }

    Map.put(FakeAccess.suiss(FakeAccess.installation_region()), "endpoints", endpoints)
  end

  defp routed(conn, path, agent) do
    if asserted?(conn), do: route(conn, conn.method, path, agent), else: send_resp(conn, 401, "")
  end

  defp route(conn, "POST", ["tenants", tenant, "pairing", "challenges"], agent) do
    send(self(), {:fake_pairing, :challenges, tenant})

    case Agent.get_and_update(agent, &pop_failure/1) do
      {status, code} -> problem(conn, status, code)
      nil -> json(conn, 201, %{"tenant" => tenant, "targets" => challenges(tenant, agent)})
    end
  end

  defp route(conn, "POST", ["tenants", tenant, "pairing"], agent) do
    {:ok, raw, conn} = read_body(conn)
    body = Jason.decode!(raw)
    send(self(), {:fake_pairing, :pairing, tenant, body})
    targets = Enum.map(body["targets"], &pair(tenant, &1, agent))
    stream = if Enum.any?(targets, &(&1["status"] == "paired")), do: stream_id(agent)
    result = %{"tenant" => tenant, "targets" => targets}
    json(conn, 200, if(stream, do: Map.put(result, "event_stream", stream), else: result))
  end

  defp route(conn, "GET", ["platform", "streams"], agent) do
    send(self(), {:fake_pairing, :streams})
    json(conn, 200, %{"streams" => state(agent).streams})
  end

  defp route(conn, "GET", ["platform", "streams", id], agent) do
    send(self(), {:fake_pairing, :stream, id})

    case Enum.find(state(agent).streams, &(&1["stream_id"] == id)) do
      nil -> problem(conn, 404, "no-such-stream")
      stream -> json(conn, 200, stream)
    end
  end

  defp route(conn, "POST", ["platform", "streams"], agent) do
    {:ok, raw, conn} = read_body(conn)
    body = Jason.decode!(raw)
    send(self(), {:fake_pairing, :open_stream, body})
    live = Enum.find(state(agent).streams, &(&1["status"] != "disabled"))

    if live do
      problem(conn, 409, "stream-exists")
    else
      stream = stream(uuid(), "enabled")
      update(agent, &%{&1 | streams: &1.streams ++ [stream]})
      json(conn, 201, stream)
    end
  end

  defp route(conn, _method, _path, _agent), do: FakeAccess.call(conn, [])

  defp pop_failure(%{challenge_failures: [failure | rest]} = state),
    do: {failure, %{state | challenge_failures: rest}}

  defp pop_failure(state), do: {nil, state}

  defp challenges(tenant, agent) do
    for %{"id" => realm} <- FakeAccess.snapshot(tenant)["realms"] do
      %{paired: paired, refused: refused} = state(agent)

      cond do
        Map.has_key?(paired, {tenant, realm}) -> paired_target(realm, paired[{tenant, realm}])
        MapSet.member?(refused, realm) -> refused_target(realm, "realm-closed")
        true -> challenge(tenant, realm, agent)
      end
    end
  end

  defp challenge(tenant, realm, agent) do
    challenge = :crypto.strong_rand_bytes(32)
    tamper = state(agent).tamper
    now = System.system_time(:millisecond)
    until = if tamper == :validity, do: now + 30_000, else: now + 600_000
    kid = if tamper == :kid, do: :crypto.strong_rand_bytes(32), else: kid()
    nonce = if tamper == :nonce, do: :crypto.strong_rand_bytes(32), else: challenge
    suffix = if tamper == :register_nonce, do: <<2>>, else: <<1>>
    update(agent, &%{&1 | issued: Map.put(&1.issued, b64(challenge), {tenant, realm})})

    %{
      "realm" => realm,
      "status" => "unpaired",
      "domain" => b64(:crypto.hash(:sha256, realm)),
      "basis" => b64(binary_part(:crypto.hash(:sha256, "basis" <> realm), 0, 16)),
      "pep" => "access-identity",
      "party" => b64(party(realm)),
      "kid" => b64(kid),
      "challenge" => b64(challenge),
      "valid_from" => time(now - 1_000),
      "valid_until" => time(until),
      "instance_create" => %{"nonce" => b64(nonce), "intent" => b64(:crypto.hash(:sha256, "i"))},
      "party_register" => %{
        "nonce" => b64(challenge <> suffix),
        "intent" => b64(:crypto.hash(:sha256, "r"))
      }
    }
  end

  defp pair(tenant, %{"realm" => realm, "challenge" => challenge} = answer, agent) do
    issued = state(agent).issued[challenge]
    signed = answer["ais"] == b64("placeholder-ais")
    registered = answer["register_ais"] == b64("placeholder-register-ais")

    if issued == {tenant, realm} and signed and registered do
      instance = binary_part(:crypto.hash(:sha256, "instance" <> realm), 0, 16)
      update(agent, &%{&1 | paired: Map.put(&1.paired, {tenant, realm}, instance)})
      paired_target(realm, instance)
    else
      refused_target(realm, "invalid-ais")
    end
  end

  defp refused_target(realm, code), do: %{"realm" => realm, "status" => "refused", "code" => code}

  defp paired_target(realm, instance) do
    %{
      "realm" => realm,
      "status" => "paired",
      "party" => b64(party(realm)),
      "instance" => b64(instance),
      "kid" => b64(kid())
    }
  end

  defp stream_id(agent) do
    case Enum.find(state(agent).streams, &(&1["status"] != "disabled")) do
      %{"stream_id" => id} ->
        id

      nil ->
        stream = stream(uuid(), "enabled")
        update(agent, &%{&1 | streams: &1.streams ++ [stream]})
        stream["stream_id"]
    end
  end

  defp party(realm), do: binary_part(:crypto.hash(:sha256, "party" <> realm), 0, 16)

  defp asserted?(conn) do
    with ["Bearer " <> assertion] <- get_req_header(conn, "authorization"),
         [encoded_header, encoded_claims, encoded_signature] <- String.split(assertion, "."),
         {:ok, %{"alg" => "ES256"}} <- decode_json(encoded_header),
         {:ok, claims} <- decode_json(encoded_claims),
         {:ok, <<r::256, s::256>>} <- Base.url_decode64(encoded_signature, padding: false) do
      input = encoded_header <> "." <> encoded_claims
      client?(claims) and verified?(input, r, s)
    else
      _refused -> false
    end
  end

  defp client?(claims) do
    client_id = Relay.Access.client_id()
    expected = [client_id, client_id, FakeAccess.issuer()]
    timed = is_integer(claims["exp"]) and claims["exp"] <= System.system_time(:second) + 300
    named = [claims["iss"], claims["sub"], claims["aud"]] == expected
    named and timed and is_binary(claims["jti"])
  end

  defp verified?(input, r, s) do
    {:ok, point} = Relay.Keys.public_key(:es256, "access-client")
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    :crypto.verify(:ecdsa, :sha256, input, der, [point, :secp256r1])
  end

  defp decode_json(part) do
    with {:ok, raw} <- Base.url_decode64(part, padding: false), do: Jason.decode(raw)
  end

  defp problem(conn, status, code) do
    body = %{"type" => "urn:suiss:access:problem:#{code}", "title" => code, "status" => status}
    body = if code, do: Map.put(body, "code", code), else: body

    conn
    |> put_resp_content_type("application/problem+json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp time(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp uuid do
    <<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>> =
      :crypto.strong_rand_bytes(16)

    Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
