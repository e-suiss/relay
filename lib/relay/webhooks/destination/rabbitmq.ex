defmodule Relay.Webhooks.Destination.Rabbitmq do
  @moduledoc """
  The RabbitMQ destination (WH-17): one persistent message published to an exchange over AMQP 0-9-1 with publisher confirms. The connection is made through `Relay.Webhooks.Destination.Socket`, so the egress rules hold for the broker address (WH-43), and it is TLS from the first byte.

  Success is the broker's `basic.ack` for the message (WH-18). The message is published as mandatory: a message no queue takes comes back as `basic.return` and counts as rejected, because nothing was written. A `basic.nack` means the broker could not take the message now. Delivery is at least once; the CloudEvents `id` is the `message_id` of the message, by which a consumer drops a duplicate.

  The configuration is `:host` (`host:port`), `:vhost` (`/` when absent), `:exchange`, `:routing_key` (empty when absent), `:cloudevents_mode` (`"binary"` when absent, or `"structured"`) and the credentials. With `:username` the endpoint's `:credential` is the password and the mechanism is PLAIN; a `:client_certificate` may be given next to it in its decoded form. Without a user name the `:client_certificate` identifies the client, the mechanism is EXTERNAL, and for a PEM certificate chain the `:credential` is its PEM private key. The password and the key are wrapped values and appear in no failure and in no receipt (WH-19).

  In binary mode the context attributes travel in the headers table with the `cloudEvents:` prefix, the content type of the message is the `datacontenttype` of the event and the body is `data`; in structured mode the body is the whole event (WH-8 (3)).

  Options: `:policy`, `:connect_timeout_ms`, `:total_timeout_ms` and `:max_frame_bytes` (the largest frame accepted from the broker and sent to it) are required; `:dns_timeout_ms`, `:resolver`, `:dialer` and `:ca_certificates` are passed to the connection.
  """

  @behaviour Relay.Webhooks.Destination

  alias Relay.Clock
  alias Relay.Redacted
  alias Relay.Webhooks.Destination.Rabbitmq.Frame
  alias Relay.Webhooks.Destination.Socket
  alias Relay.Webhooks.Envelope

  @socket_options [:connect_timeout_ms, :dns_timeout_ms, :resolver, :dialer, :ca_certificates]
  @closes [:connection_close, :channel_close]
  @frame_min 4096
  @frame_overhead Frame.overhead()
  @short 255
  @capabilities [
    {"publisher_confirms", true},
    {"basic.nack", true},
    {"authentication_failure_close", true}
  ]
  @properties [{"product", "suiss-relay"}, {"capabilities", @capabilities}]
  @rejected_codes [311, 530]

  # WH-17
  # WH-18
  @impl Relay.Webhooks.Destination
  def deliver(config, prepared, opts) when is_map(config) and is_list(opts) do
    started = Clock.monotonic_ms()

    result =
      case plan(config, prepared) do
        {:ok, plan} -> attempt(plan, opts)
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

  defp plan(config, prepared) do
    with {:ok, endpoint} <- endpoint(config),
         {:ok, route} <- route(config),
         {:ok, auth} <- auth(config),
         {:ok, message} <- message(config, prepared) do
      {:ok, Map.merge(route, %{endpoint: endpoint, auth: auth, message: message})}
    end
  end

  defp endpoint(config) do
    case Socket.endpoint(Map.get(config, :host)) do
      {:ok, endpoint} -> {:ok, endpoint}
      :error -> invalid("invalid_host")
    end
  end

  defp route(config) do
    route = %{
      vhost: Map.get(config, :vhost) || "/",
      exchange: Map.get(config, :exchange),
      routing_key: Map.get(config, :routing_key) || ""
    }

    cond do
      not short?(route.vhost, 1) -> invalid("invalid_vhost")
      not short?(route.exchange, 1) -> invalid("invalid_exchange")
      not short?(route.routing_key, 0) -> invalid("invalid_routing_key")
      true -> {:ok, route}
    end
  end

  defp short?(value, min),
    do: is_binary(value) and byte_size(value) >= min and byte_size(value) <= @short

  # WH-17
  # WH-19
  defp auth(config) do
    username = Map.get(config, :username)
    certificate = Map.get(config, :client_certificate)
    credential = Map.get(config, :credential)

    if is_binary(username) and username != "",
      do: plain(username, credential, certificate),
      else: external(certificate, credential)
  end

  defp plain(username, credential, certificate) do
    case {password?(credential), decoded(certificate)} do
      {true, {:ok, certificate}} ->
        auth = %{mechanism: "PLAIN", username: username, secret: credential}
        {:ok, Map.put(auth, :certificate, certificate)}

      _unusable ->
        invalid("invalid_credentials")
    end
  end

  defp password?(credential),
    do: Redacted.redacted?(credential) and is_binary(Redacted.expose(credential))

  defp decoded(certificate) when is_binary(certificate), do: :error
  defp decoded(certificate), do: Socket.client_certificate(certificate, nil)

  defp external(certificate, credential) do
    case Socket.client_certificate(certificate, credential) do
      {:ok, %{} = certificate} -> {:ok, %{mechanism: "EXTERNAL", certificate: certificate}}
      _unusable -> invalid("invalid_credentials")
    end
  end

  defp response(%{mechanism: "PLAIN", username: username, secret: secret}),
    do: <<0, username::binary, 0, Redacted.expose(secret)::binary>>

  defp response(%{mechanism: "EXTERNAL"}), do: ""

  # WH-8 (3)
  defp message(config, prepared) do
    case Map.get(config, :cloudevents_mode) || "binary" do
      "binary" -> encodable(binary(prepared))
      "structured" -> encodable(structured(prepared))
      _other -> invalid("invalid_cloudevents_mode")
    end
  end

  defp binary(prepared) do
    %{
      content_type: data_content_type(prepared.attributes),
      headers: Envelope.binary_headers(prepared.attributes, :amqp),
      delivery_mode: 2,
      message_id: prepared.id,
      body: prepared.data
    }
  end

  defp structured(prepared) do
    %{
      content_type: prepared.content_type,
      headers: [{"cloudEvents:id", prepared.id}],
      delivery_mode: 2,
      message_id: prepared.id,
      body: prepared.body
    }
  end

  defp data_content_type(attributes) do
    case List.keyfind(attributes, "datacontenttype", 0) do
      {_name, value} -> value
      nil -> "application/json"
    end
  end

  defp encodable(message) do
    names? = Enum.all?(message.headers, fn {name, _value} -> short?(name, 1) end)

    if names? and short?(message.content_type, 1) and short?(message.message_id, 1),
      do: {:ok, message},
      else: invalid("message_not_encodable")
  end

  # WH-43
  defp attempt(plan, opts) do
    policy = Keyword.fetch!(opts, :policy)
    deadline = Socket.deadline(Keyword.fetch!(opts, :total_timeout_ms))
    max = Keyword.fetch!(opts, :max_frame_bytes)
    options = Keyword.take(opts, @socket_options) ++ [client_certificate: plan.auth.certificate]

    case Socket.connect(policy, plan.endpoint, options) do
      {:ok, socket} -> exchange(%{socket: socket, deadline: deadline, max: max}, plan)
      {:error, error} -> {:error, error}
    end
  end

  defp exchange(io, plan) do
    result =
      with {:ok, frame_max} <- open(io, plan),
           :ok <- channel(io),
           :ok <- publish(io, plan, frame_max) do
        leave(io)
      end

    :ok = Socket.close(io.socket)
    located(result, Socket.address(io.socket))
  end

  defp located(:ok, address), do: {:ok, address}
  defp located({:error, error}, address), do: {:error, Map.put_new(error, :address, address)}

  # WH-17
  defp open(io, plan) do
    with :ok <- Socket.write(io.socket, Frame.protocol_header()),
         {:ok, start} <- expect(io, :connection_start),
         :ok <- offered(start.mechanisms, plan.auth.mechanism),
         :ok <- send_method(io, 0, {:connection_start_ok, start_ok(plan.auth)}),
         {:ok, tune} <- authenticated(expect(io, :connection_tune)),
         {:ok, frame_max} <- frame_max(tune.frame_max, io.max),
         :ok <- Socket.write(io.socket, tuned(frame_max, plan.vhost)),
         {:ok, _opened} <- expect(io, :connection_open_ok) do
      {:ok, frame_max}
    end
  end

  defp offered(mechanisms, mechanism) do
    if mechanism in mechanisms,
      do: :ok,
      else: {:error, failure(:credentials, "mechanism_not_offered")}
  end

  defp start_ok(auth) do
    start_ok = %{properties: @properties, mechanism: auth.mechanism, locale: "en_US"}
    Map.put(start_ok, :response, response(auth))
  end

  defp authenticated({:ok, tune}), do: {:ok, tune}

  defp authenticated({:error, %{reason: "amqp_" <> _code}}),
    do: {:error, failure(:credentials, "authentication_failed")}

  defp authenticated({:error, %{class: :connect, reason: "closed"}}),
    do: {:error, failure(:credentials, "authentication_failed")}

  defp authenticated({:error, error}), do: {:error, error}

  defp frame_max(0, max), do: negotiated(max)
  defp frame_max(offered, max), do: negotiated(min(offered, max))

  defp negotiated(frame_max) when frame_max >= @frame_min, do: {:ok, frame_max}
  defp negotiated(_frame_max), do: {:error, failure(:protocol, "frame_max_too_small")}

  defp tuned(frame_max, vhost) do
    tune = %{channel_max: 1, frame_max: frame_max, heartbeat: 0}

    [
      Frame.method(0, {:connection_tune_ok, tune}),
      Frame.method(0, {:connection_open, %{vhost: vhost}})
    ]
  end

  defp channel(io) do
    with :ok <- send_method(io, 1, {:channel_open, %{}}),
         {:ok, _opened} <- expect(io, :channel_open_ok),
         :ok <- send_method(io, 1, {:confirm_select, %{}}),
         {:ok, _selected} <- expect(io, :confirm_select_ok) do
      :ok
    end
  end

  # WH-18
  defp publish(io, plan, frame_max) do
    publish = %{exchange: plan.exchange, routing_key: plan.routing_key, mandatory: true}
    method = Frame.method(1, {:basic_publish, publish})
    properties = Map.delete(plan.message, :body)
    content = Frame.content(1, properties, plan.message.body, frame_max)

    with :ok <- Socket.write(io.socket, [method, content]),
         {:ok, _confirm} <- expect(io, :basic_ack) do
      :ok
    end
  end

  defp leave(io) do
    close = {:connection_close, %{code: 200, text: "done"}}

    _closed =
      case send_method(io, 0, close) do
        :ok -> expect(io, :connection_close_ok)
        {:error, error} -> {:error, error}
      end

    :ok
  end

  defp send_method(io, channel, method),
    do: Socket.write(io.socket, Frame.method(channel, method))

  defp expect(io, wanted) do
    case next(io) do
      {:ok, :heartbeat} -> expect(io, wanted)
      {:ok, decoded} -> verdict(decoded, wanted)
      {:error, error} -> {:error, error}
    end
  end

  # WH-18
  defp verdict({wanted, arguments}, wanted), do: {:ok, arguments}
  defp verdict({:basic_nack, _arguments}, _wanted), do: {:error, failure(:unavailable, "nacked")}

  defp verdict({:basic_return, _arguments}, _wanted),
    do: {:error, failure(:rejected, "unroutable")}

  defp verdict({name, %{code: code}}, _wanted) when name in @closes, do: {:error, closed(code)}
  defp verdict(_decoded, _wanted), do: {:error, failure(:protocol, "unexpected_frame")}

  defp closed(403), do: failure(:credentials, "amqp_403")

  defp closed(code) when code in 400..499 or code in @rejected_codes,
    do: failure(:rejected, "amqp_" <> Integer.to_string(code))

  defp closed(code), do: failure(:unavailable, "amqp_" <> Integer.to_string(code))

  defp next(io) do
    with {:ok, head} <- Socket.read(io.socket, 7, io.deadline),
         {:ok, {type, size}} <- head(head, io.max),
         {:ok, rest} <- Socket.read(io.socket, size + 1, io.deadline) do
      decode(type, size, rest)
    end
  end

  defp head(head, max) do
    case Frame.head(head) do
      {:ok, {type, _channel, size}} when size + @frame_overhead <= max -> {:ok, {type, size}}
      {:ok, _oversized} -> {:error, failure(:protocol, "frame_too_large")}
      :error -> {:error, failure(:protocol, "malformed_frame")}
    end
  end

  defp decode(type, size, rest) do
    case Frame.decode(type, size, rest) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, failure(:protocol, "malformed_frame")}
    end
  end

  defp failure(class, reason), do: %{class: class, reason: reason}

  defp invalid(reason), do: {:error, failure(:invalid, reason)}
end
