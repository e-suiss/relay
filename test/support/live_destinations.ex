defmodule RelayTest.LiveDestinations do
  @moduledoc """
  The real brokers and the object store of the live destination suite (WH-58): the services `deploy/live/up.sh` starts, each on its own address of a private network and under a throwaway certificate authority.

  The suite reaches them the way an installation would: the names resolve through a resolver of the installation, the network is on the self-host allow-list, the broker ports are the extra ports and the certificate authority is the one the installation trusts. What a destination wrote is read back by other means than the client under test: the broker's own command line tools inside its container, the management API of RabbitMQ and a request to the object store signed by `curl`.
  """

  use Boundary, top_level?: true, check: [out: false]

  import ExUnit.Assertions

  alias Relay.Webhooks.Egress.Policy
  alias Relay.Webhooks.Settings
  alias RelayTest.WebhookDestinations

  @hosts %{
    "kafka.live.relay.test" => {10, 123, 45, 11},
    "nats.live.relay.test" => {10, 123, 45, 12},
    "nats-token.live.relay.test" => {10, 123, 45, 13},
    "rabbitmq.live.relay.test" => {10, 123, 45, 14},
    "minio.live.relay.test" => {10, 123, 45, 15}
  }
  @network "10.123.45.0/24"
  @ports [9093, 4222, 5671, 9000]
  @secret "relay-live-secret"
  @token "relay-live-token"
  @access_key_id "RELAYLIVEACCESSKEY0"
  @topic "relay-live"
  @stream "RELAY_LIVE"
  @bucket "relay-live"
  @queue "relay-live"
  @kafka_bin "/opt/kafka/bin/"
  @kafka_local "127.0.0.1:9092"
  @management "http://10.123.45.14:15672/api/queues/%2F/"
  @store "https://minio.live.relay.test:9000/"

  @type record :: %{partition: integer(), headers: String.t(), key: String.t(), value: String.t()}

  defmodule Resolver do
    @moduledoc "The resolver of the live suite: the names of the services, at their addresses on the private network."

    @behaviour Relay.Webhooks.Egress.Resolver

    @impl Relay.Webhooks.Egress.Resolver
    def resolve(host, _timeout_ms), do: RelayTest.LiveDestinations.resolve(host)
  end

  @doc "The addresses of a service name."
  @spec resolve(String.t()) :: {:ok, [:inet.ip_address(), ...]} | {:error, :nxdomain}
  def resolve(host) do
    case Map.fetch(@hosts, host) do
      {:ok, address} -> {:ok, [address]}
      :error -> {:error, :nxdomain}
    end
  end

  @doc "The address of a service name, as text."
  @spec address(String.t()) :: String.t()
  def address(host), do: @hosts |> Map.fetch!(host) |> :inet.ntoa() |> List.to_string()

  @doc "The password of the users, the secret access key of the store."
  @spec secret() :: String.t()
  def secret, do: @secret

  @doc "The token of the NATS server that authenticates with one."
  @spec token() :: String.t()
  def token, do: @token

  @doc "The access key identifier of the store."
  @spec access_key_id() :: String.t()
  def access_key_id, do: @access_key_id

  @doc "The NKey seed of the user the NATS server knows by its public key."
  @spec nkey_seed() :: String.t()
  def nkey_seed, do: "nkey.seed" |> file() |> String.trim()

  defp directory, do: System.get_env("RELAY_LIVE_DIR") || Path.expand("deploy/live/run")

  defp file(name), do: directory() |> Path.join(name) |> File.read!()

  defp authority do
    for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(file("ca.crt")), do: der
  end

  @doc "The installation configuration of the suite: the allow-listed network, the broker ports and the trusted certificate authority."
  @spec installation() :: keyword()
  def installation do
    [
      deployment: :self_hosted,
      extra_ports: @ports,
      allow_list: [@network],
      resolver: Resolver,
      destination_options: [resolver: Resolver, ca_certificates: authority()]
    ]
  end

  @doc "Makes the engine deliver to the live services until the test ends; returns the previous configuration."
  @spec install() :: keyword()
  def install do
    previous = Application.get_env(:relay, Relay.Webhooks, [])
    config = [runtime: WebhookDestinations.Runtime, destinations: %{}] ++ installation()
    Application.put_env(:relay, Relay.Webhooks, Keyword.merge(previous, config))
    previous
  end

  @doc "The options the engine calls a destination with under `installation/0`, with the limits of the contract."
  @spec options() :: keyword()
  def options do
    {:ok, policy} =
      Policy.new(deployment: :self_hosted, extra_ports: @ports, allow_list: [@network])

    request = Settings.request()
    limits = Settings.destination_limits()

    [
      policy: policy,
      resolver: Resolver,
      ca_certificates: authority(),
      connect_timeout_ms: request.connect_ms,
      total_timeout_ms: request.total_ms,
      dns_timeout_ms: request.connect_ms,
      max_response_bytes: request.response_max,
      max_frame_bytes: limits.max_frame_bytes,
      ack_timeout_ms: limits.ack_timeout_ms,
      max_scram_iterations: limits.max_scram_iterations
    ]
  end

  @doc "A name no other test uses."
  @spec unique() :: String.t()
  def unique, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  @doc "Every record of the topic as the broker's console consumer prints it: partition, headers, key and value."
  @spec kafka_records() :: [record()]
  def kafka_records do
    arguments = [
      "exec",
      "relay-live-kafka",
      @kafka_bin <> "kafka-console-consumer.sh",
      "--bootstrap-server",
      @kafka_local,
      "--topic",
      @topic,
      "--from-beginning",
      "--timeout-ms",
      "6000",
      "--property",
      "print.partition=true",
      "--property",
      "print.headers=true",
      "--property",
      "print.key=true"
    ]

    {output, _status} = System.cmd("docker", arguments)

    for "Partition:" <> line <- String.split(output, "\n") do
      [partition, headers, key, value] = String.split(line, "\t", parts: 4)
      %{partition: String.to_integer(partition), headers: headers, key: key, value: value}
    end
  end

  @doc "Produces one record per key with the broker's own console producer, the Java client, with `value` as the value."
  @spec kafka_produce([String.t()], String.t()) :: :ok
  def kafka_produce(keys, value) do
    producer = [
      "docker exec -i relay-live-kafka",
      @kafka_bin <> "kafka-console-producer.sh",
      "--bootstrap-server",
      @kafka_local,
      "--topic",
      @topic,
      "--property parse.key=true",
      "--property 'key.separator=|'"
    ]

    lines = Enum.map(keys, &(&1 <> "|" <> value))
    script = ~s(printf '%s\\n' "$@" | ) <> Enum.join(producer, " ")
    {output, status} = System.cmd("sh", ["-c", script, "sh" | lines], stderr_to_stdout: true)
    assert status == 0, output
    :ok
  end

  @doc "The last message of a subject in the stream of a NATS server, as the `nats` command line tool reads it: the sequence, the header block and the payload. `credentials` are the tool's own flags."
  @spec nats_message(String.t(), String.t(), [String.t()]) ::
          %{subject: String.t(), seq: integer(), headers: String.t(), data: binary()}
  def nats_message(host, subject, credentials) do
    connection = ["--tlsca", "/live/run/ca.crt", "--server", "tls://" <> host <> ":4222"]
    read = ["stream", "get", @stream, "--last-for", subject, "--json"]
    arguments = ["exec", "relay-live-tools", "nats"] ++ connection ++ credentials ++ read
    {output, status} = System.cmd("docker", arguments)
    assert status == 0, output
    message = Jason.decode!(output)

    %{
      subject: message["subject"],
      seq: message["seq"],
      headers: Base.decode64!(Map.get(message, "hdrs", "")),
      data: Base.decode64!(Map.get(message, "data", ""))
    }
  end

  @doc "The flags of the `nats` tool for the user with a password."
  @spec nats_user() :: [String.t()]
  def nats_user, do: ["--user", "relay", "--password", @secret]

  @doc "The flags of the `nats` tool for the token."
  @spec nats_token() :: [String.t()]
  def nats_token, do: ["--user", @token]

  @doc "Takes every message out of the queue through the management API of RabbitMQ."
  @spec rabbitmq_messages() :: [map()]
  def rabbitmq_messages do
    body = %{count: 100, ackmode: "ack_requeue_false", encoding: "auto", truncate: 4_000_000}

    arguments = [
      "-fsS",
      "-u",
      "relay:" <> @secret,
      "-H",
      "content-type: application/json",
      "-X",
      "POST",
      @management <> @queue <> "/get",
      "-d",
      Jason.encode!(body)
    ]

    {output, status} = System.cmd("curl", arguments)
    assert status == 0, output
    Jason.decode!(output)
  end

  @doc "The name of the bucket."
  @spec bucket() :: String.t()
  def bucket, do: @bucket

  @doc "Reads an object of the bucket with a request `curl` signs: its status, its content type and its bytes."
  @spec object(String.t()) :: %{status: integer(), content_type: String.t(), body: binary()}
  def object(key) do
    path = key |> String.split("/") |> Enum.map_join("/", &segment/1)

    arguments = [
      "-sS",
      "--cacert",
      Path.join(directory(), "ca.crt"),
      "--resolve",
      "minio.live.relay.test:9000:" <> address("minio.live.relay.test"),
      "--aws-sigv4",
      "aws:amz:us-east-1:s3",
      "--user",
      @access_key_id <> ":" <> @secret,
      "-w",
      "\n%{http_code}\n%{content_type}",
      @store <> @bucket <> "/" <> path
    ]

    {output, status} = System.cmd("curl", arguments)
    assert status == 0, output
    [content_type, code | body] = output |> String.split("\n") |> Enum.reverse()
    body = body |> Enum.reverse() |> Enum.join("\n")
    %{status: String.to_integer(code), content_type: content_type, body: body}
  end

  defp segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
