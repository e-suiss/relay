defmodule Relay.Webhooks.Destination.NatsJetstream do
  @moduledoc """
  The NATS JetStream destination (WH-17): one message published to a subject with a reply inbox, over the NATS client protocol. Every connection is made through `Relay.Webhooks.Destination.Socket`, so the egress rules hold for each server address (WH-43). The servers are tried in order; the next one is tried only when a server cannot be reached.

  A NATS server speaks first, in plain text: the connection reads its `INFO` line and nothing else, requires that the server offers TLS and upgrades before anything is sent. A server without TLS is not used.

  Success is the publish acknowledgement of the stream, a reply with the stream name and the sequence (WH-18). A reply that carries an error is a refusal when its code is below 500 and unavailability otherwise; no reply at all because nothing listens on the subject (`503`, no responders) is unavailability. Delivery is at least once: the CloudEvents `id` is sent as `Nats-Msg-Id`, by which JetStream drops a duplicate inside its deduplication window.

  The configuration is `:servers` (a list of `host:port`), `:subject`, `:cloudevents_mode` (`"binary"` when absent, or `"structured"`) and the credentials. With `:username` the endpoint's `:credential` is the password. Without a user name a `:client_certificate` identifies the client, and for a PEM certificate chain the `:credential` is its PEM private key. With neither, a `:credential` that reads as an NKey user seed signs the server's nonce, and any other `:credential` is sent as the authentication token. Every secret is a wrapped value and appears in no failure and in no receipt (WH-19).

  In binary mode the context attributes travel as `ce-` headers, with `ce-datacontenttype`, and the payload is `data`; in structured mode the payload is the whole event (WH-8 (3)).

  Options: `:policy`, `:connect_timeout_ms`, `:total_timeout_ms` and `:max_frame_bytes` (the longest line and the largest message accepted from the server) are required; `:dns_timeout_ms`, `:resolver`, `:dialer` and `:ca_certificates` are passed to the connection.
  """

  @behaviour Relay.Webhooks.Destination

  alias Relay.Clock
  alias Relay.Redacted
  alias Relay.Webhooks.Destination.NatsJetstream.Nkey
  alias Relay.Webhooks.Destination.Socket
  alias Relay.Webhooks.Envelope

  @socket_options [:connect_timeout_ms, :dns_timeout_ms, :resolver, :dialer, :ca_certificates]
  @next_server [:connect, :timeout, :dns]
  @subject ~r/\A[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\z/
  @subject_bytes 256
  @connect %{
    "verbose" => false,
    "pedantic" => false,
    "tls_required" => true,
    "headers" => true,
    "no_responders" => true,
    "lang" => "elixir",
    "version" => "1",
    "name" => "suiss-relay",
    "protocol" => 1
  }

  # WH-17
  # WH-18
  @impl Relay.Webhooks.Destination
  def deliver(config, prepared, opts) when is_map(config) and is_list(opts) do
    started = Clock.monotonic_ms()

    result =
      case plan(config, prepared) do
        {:ok, plan} -> attempt(plan.servers, bounded(plan, opts), opts)
        {:error, error} -> {:error, error}
      end

    timed(result, max(Clock.monotonic_ms() - started, 0))
  end

  defp timed({:ok, address}, duration_ms),
    do: {:ok, %{kind: :write, duration_ms: duration_ms, address: address}}

  defp timed({:error, error}, duration_ms) do
    failure = %{
      class: error.class,
      reason: error.reason,
      duration_ms: duration_ms,
      address: Map.get(error, :address)
    }

    {:error, failure}
  end

  # WH-24
  defp bounded(plan, opts) do
    deadline = Socket.deadline(Keyword.fetch!(opts, :total_timeout_ms))
    Map.merge(plan, %{deadline: deadline, max: Keyword.fetch!(opts, :max_frame_bytes)})
  end

  defp plan(config, prepared) do
    with {:ok, servers} <- servers(Map.get(config, :servers)),
         {:ok, subject} <- subject(Map.get(config, :subject)),
         {:ok, auth} <- auth(config),
         {:ok, message} <- message(config, prepared) do
      {:ok, %{servers: servers, subject: subject, auth: auth, message: message}}
    end
  end

  defp servers([_first | _rest] = servers) do
    parsed = Enum.map(servers, &Socket.endpoint/1)

    if :error in parsed,
      do: invalid("invalid_server"),
      else: {:ok, Enum.map(parsed, fn {:ok, endpoint} -> endpoint end)}
  end

  defp servers(_servers), do: invalid("invalid_server")

  defp subject(subject) when is_binary(subject) and byte_size(subject) <= @subject_bytes do
    if Regex.match?(@subject, subject), do: {:ok, subject}, else: invalid("invalid_subject")
  end

  defp subject(_subject), do: invalid("invalid_subject")

  # WH-17
  # WH-19
  defp auth(config) do
    username = Map.get(config, :username)
    certificate = Map.get(config, :client_certificate)
    credential = Map.get(config, :credential)

    cond do
      is_binary(username) and username != "" -> password(username, credential, certificate)
      certificate != nil -> certificate(certificate, credential)
      credential != nil -> secret(credential)
      true -> {:ok, %{kind: :none, certificate: nil}}
    end
  end

  defp password(username, credential, certificate) do
    case {text?(credential) and utf8?(username), decoded(certificate)} do
      {true, {:ok, certificate}} ->
        auth = %{kind: :password, username: username, secret: credential}
        {:ok, Map.put(auth, :certificate, certificate)}

      _unusable ->
        invalid("invalid_credentials")
    end
  end

  defp text?(credential),
    do: Redacted.redacted?(credential) and utf8?(Redacted.expose(credential))

  defp utf8?(text), do: is_binary(text) and String.valid?(text)

  defp decoded(certificate) when is_binary(certificate), do: :error
  defp decoded(certificate), do: Socket.client_certificate(certificate, nil)

  defp certificate(certificate, credential) do
    case Socket.client_certificate(certificate, credential) do
      {:ok, %{} = certificate} -> {:ok, %{kind: :none, certificate: certificate}}
      _unusable -> invalid("invalid_credentials")
    end
  end

  defp secret(credential) do
    if text?(credential),
      do: {:ok, token_or_nkey(credential)},
      else: invalid("invalid_credentials")
  end

  defp token_or_nkey(credential) do
    case Nkey.user(Redacted.expose(credential)) do
      {:ok, %{public: public, seed: seed}} ->
        %{kind: :nkey, public: public, secret: seed, certificate: nil}

      :error ->
        %{kind: :token, secret: credential, certificate: nil}
    end
  end

  # WH-8 (3)
  # WH-18
  defp message(config, prepared) do
    case Map.get(config, :cloudevents_mode) || "binary" do
      "binary" -> sendable(prepared.id, binary_headers(prepared), prepared.data)
      "structured" -> sendable(prepared.id, structured_headers(prepared), prepared.body)
      _other -> invalid("invalid_cloudevents_mode")
    end
  end

  defp structured_headers(prepared), do: [{"content-type", prepared.content_type}]

  defp binary_headers(prepared) do
    data_content_type =
      for {"datacontenttype", value} <- prepared.attributes, do: {"ce-datacontenttype", value}

    Envelope.binary_headers(prepared.attributes, :nats) ++ data_content_type
  end

  defp sendable(id, headers, payload) do
    headers = [{"Nats-Msg-Id", id} | headers]

    if Enum.all?(headers, &header?/1),
      do: {:ok, %{headers: headers, payload: payload}},
      else: invalid("invalid_header")
  end

  defp header?({name, value}),
    do: line?(name) and line?(value) and name != "" and not String.contains?(name, ":")

  defp line?(text), do: is_binary(text) and not String.contains?(text, ["\r", "\n"])

  # WH-43
  defp attempt([server | rest], plan, opts) do
    policy = Keyword.fetch!(opts, :policy)
    options = Keyword.take(opts, @socket_options) ++ connection_options(plan.auth)

    case Socket.connect(policy, server, options) do
      {:ok, socket} ->
        converse(%{socket: socket, deadline: plan.deadline, max: plan.max, buffer: ""}, plan)

      {:error, %{class: class}} when class in @next_server and rest != [] ->
        attempt(rest, plan, opts)

      {:error, error} ->
        {:error, error}
    end
  end

  defp connection_options(auth), do: [mode: :plain, client_certificate: auth.certificate]

  defp converse(io, plan) do
    case greet(io) do
      {:ok, io, info} -> finish(io, publish(io, plan, info))
      {:error, error} -> finish(io, {:error, error})
    end
  end

  defp finish(io, result) do
    :ok = Socket.close(io.socket)
    located(result, Socket.address(io.socket))
  end

  defp located(:ok, address), do: {:ok, address}
  defp located({:error, error}, address), do: {:error, Map.put_new(error, :address, address)}

  defp greet(io) do
    with {:ok, info, io} <- info(io),
         :ok <- tls_offered(info),
         {:ok, socket} <- Socket.upgrade(io.socket) do
      {:ok, %{io | socket: socket}, info}
    end
  end

  defp info(io) do
    with {:ok, "INFO " <> json, %{buffer: ""} = io} <- line(io),
         {:ok, %{} = info} <- Jason.decode(json) do
      {:ok, info, io}
    else
      {:error, %{class: _class} = error} -> {:error, error}
      _other -> {:error, failure(:protocol, "invalid_info")}
    end
  end

  defp tls_offered(info) do
    if info["tls_required"] == true or info["tls_available"] == true,
      do: :ok,
      else: {:error, failure(:tls, "tls_not_offered")}
  end

  defp publish(io, plan, info) do
    inbox = "_INBOX." <> Base.url_encode64(Relay.Random.bytes(16), padding: false)
    opening = [connect(plan.auth, info), "SUB ", inbox, " 1\r\nPING\r\n"]

    with :ok <- Socket.write(io.socket, opening),
         {:ok, io} <- pong(io),
         :ok <- Socket.write(io.socket, hpub(plan.subject, inbox, plan.message)) do
      acknowledgement(io)
    end
  end

  # WH-17
  # WH-19
  defp connect(auth, info),
    do: ["CONNECT ", Jason.encode!(Map.merge(@connect, credentials(auth, info))), "\r\n"]

  defp credentials(%{kind: :password, username: username, secret: secret}, _info),
    do: %{"user" => username, "pass" => Redacted.expose(secret)}

  defp credentials(%{kind: :token, secret: secret}, _info),
    do: %{"auth_token" => Redacted.expose(secret)}

  defp credentials(%{kind: :nkey, public: public, secret: seed}, info) do
    signature = Nkey.sign(seed, nonce(info))
    %{"nkey" => public, "sig" => Base.url_encode64(signature, padding: false)}
  end

  defp credentials(%{kind: :none}, _info), do: %{}

  defp nonce(%{"nonce" => nonce}) when is_binary(nonce), do: nonce
  defp nonce(_info), do: ""

  # WH-18
  defp hpub(subject, inbox, %{headers: headers, payload: payload}) do
    lines = Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)
    block = IO.iodata_to_binary(["NATS/1.0\r\n", lines, "\r\n"])
    sizes = [Integer.to_string(byte_size(block)), " ", total(block, payload)]
    ["HPUB ", subject, " ", inbox, " ", sizes, "\r\n", block, payload, "\r\n"]
  end

  defp total(block, payload), do: Integer.to_string(byte_size(block) + byte_size(payload))

  defp pong(io) do
    case line(io) do
      {:ok, "PONG", io} -> {:ok, io}
      {:ok, other, io} -> idle(other, io, &pong/1)
      {:error, error} -> {:error, error}
    end
  end

  # WH-18
  defp acknowledgement(io) do
    case line(io) do
      {:ok, "MSG " <> head, io} -> reply(io, sizes(1, head))
      {:ok, "HMSG " <> head, io} -> reply(io, sizes(2, head))
      {:ok, other, io} -> idle(other, io, &acknowledgement/1)
      {:error, error} -> {:error, error}
    end
  end

  defp idle("PING", io, continue) do
    case Socket.write(io.socket, "PONG\r\n") do
      :ok -> continue.(io)
      {:error, error} -> {:error, error}
    end
  end

  defp idle("+OK", io, continue), do: continue.(io)
  defp idle("INFO " <> _json, io, continue), do: continue.(io)
  defp idle("-ERR " <> message, _io, _continue), do: {:error, server_error(message)}
  defp idle(_other, _io, _continue), do: {:error, failure(:protocol, "unexpected_line")}

  defp server_error(message) do
    message = String.downcase(message, :ascii)

    cond do
      String.contains?(message, ["authorization", "authentication"]) ->
        failure(:credentials, "authorization_violation")

      String.contains?(message, "permissions") ->
        failure(:credentials, "permissions_violation")

      String.contains?(message, "maximum payload") ->
        failure(:rejected, "payload_too_large")

      true ->
        failure(:protocol, "server_error")
    end
  end

  defp sizes(count, head) do
    numbers = head |> String.split(" ", trim: true) |> Enum.take(-count) |> Enum.map(&number/1)

    case numbers do
      [total] when is_integer(total) -> {:ok, 0, total}
      [header, total] when is_integer(header) and is_integer(total) -> {:ok, header, total}
      _other -> :error
    end
  end

  defp number(text) do
    case Integer.parse(text) do
      {number, ""} when number >= 0 -> number
      _other -> nil
    end
  end

  defp reply(%{max: max} = io, {:ok, header, total}) when header <= total and total <= max do
    case payload(io, total) do
      {:ok, payload} -> verdict(binary_part(payload, 0, header), payload, header)
      {:error, error} -> {:error, error}
    end
  end

  defp reply(_io, _sizes), do: {:error, failure(:protocol, "invalid_message")}

  # WH-18
  defp verdict("NATS/1.0 503" <> _status, _payload, _header),
    do: {:error, failure(:unavailable, "no_responders")}

  defp verdict(_headers, payload, header) do
    body = binary_part(payload, header, byte_size(payload) - header)

    case Jason.decode(body) do
      {:ok, %{"error" => %{} = error}} -> {:error, refusal(error)}
      {:ok, %{"stream" => stream, "seq" => seq}} when is_binary(stream) and is_integer(seq) -> :ok
      _other -> {:error, failure(:protocol, "invalid_acknowledgement")}
    end
  end

  defp refusal(%{"code" => code} = error) when is_integer(code) and code >= 500,
    do: failure(:unavailable, error_reason(error))

  defp refusal(error), do: failure(:rejected, error_reason(error))

  defp error_reason(%{"err_code" => code}) when is_integer(code),
    do: "nats_error_" <> Integer.to_string(code)

  defp error_reason(%{"code" => code}) when is_integer(code),
    do: "nats_error_" <> Integer.to_string(code)

  defp error_reason(_error), do: "nats_error"

  defp line(%{buffer: buffer, max: max} = io) do
    case :binary.split(buffer, "\r\n") do
      [line, rest] when byte_size(line) <= max -> {:ok, line, %{io | buffer: rest}}
      [_line, _rest] -> {:error, failure(:protocol, "frame_too_large")}
      [_partial] -> more(io, &line/1)
    end
  end

  defp payload(io, size) do
    if byte_size(io.buffer) >= size + 2,
      do: terminated(binary_part(io.buffer, 0, size), binary_part(io.buffer, size, 2)),
      else: more(io, &payload(&1, size))
  end

  defp terminated(payload, "\r\n"), do: {:ok, payload}
  defp terminated(_payload, _other), do: {:error, failure(:protocol, "invalid_message")}

  defp more(%{buffer: buffer, max: max}, _continue) when byte_size(buffer) > max + 2,
    do: {:error, failure(:protocol, "frame_too_large")}

  defp more(io, continue) do
    case Socket.read(io.socket, 0, io.deadline) do
      {:ok, data} -> continue.(%{io | buffer: io.buffer <> data})
      {:error, error} -> {:error, error}
    end
  end

  defp failure(class, reason), do: %{class: class, reason: reason}

  defp invalid(reason), do: {:error, failure(:invalid, reason)}
end
