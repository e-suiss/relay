defmodule RelayTest.DestinationFixture do
  @moduledoc """
  Shared pieces of the destination tests: a resolver and an HTTP transport that run in the test process, the options a destination is called with and a prepared message. The transport sends `{:sent, connection, request}` to the test and answers with what `answer/2` registered for the host, 200 by default; an answer may be a function of the request.
  """

  use Boundary, top_level?: true, check: [out: false]

  alias Relay.Webhooks.Destination
  alias Relay.Webhooks.Egress.Policy
  alias Relay.Webhooks.Envelope

  defmodule Resolver do
    @moduledoc false
    @behaviour Relay.Webhooks.Egress.Resolver

    @impl Relay.Webhooks.Egress.Resolver
    def resolve(host, _timeout_ms), do: Process.get({:dns, host}, {:ok, [{203, 0, 114, 10}]})
  end

  defmodule Transport do
    @moduledoc false
    @behaviour Relay.Webhooks.Egress.Transport

    @ok {:ok, %{status: 200, headers: [], body: "", truncated: false}}

    @impl Relay.Webhooks.Egress.Transport
    def request(connection, request) do
      send(self(), {:sent, connection, request})

      case Process.get({:answer, connection.host}, @ok) do
        answer when is_function(answer, 1) -> answer.(request)
        answer -> answer
      end
    end
  end

  @now ~U[2026-11-16 08:00:00Z]

  @doc "The time the fixture's options fix an attempt at."
  @spec now() :: DateTime.t()
  def now, do: @now

  @doc "The options of a delivery through the fake resolver and transport, with `extra` merged in."
  @spec options(keyword()) :: keyword()
  def options(extra \\ []) do
    {:ok, policy} = Policy.new(deployment: :saas)

    base = [
      policy: policy,
      connect_timeout_ms: 5_000,
      total_timeout_ms: 20_000,
      max_response_bytes: 8_192,
      resolver: Resolver,
      transport: Transport,
      now: @now
    ]

    Keyword.merge(base, extra)
  end

  @doc "A prepared message of one event; `fields` replace the fields of its envelope."
  @spec prepared(map(), pos_integer()) :: Destination.prepared()
  def prepared(fields \\ %{}, attempt \\ 1) do
    base = %{
      id: "evt_1",
      source: "https://shop.example/orders",
      type: "order.shipped",
      time: @now,
      subject: "order/o-1",
      seq: 7,
      data: %{"order_id" => "o-1"}
    }

    {:ok, envelope} = Envelope.new(:destination, Map.merge(base, fields))
    Destination.prepare(envelope, Envelope.encode(envelope), [], attempt)
  end

  @doc "Registers the answer of the transport for a host."
  @spec answer(String.t(), term()) :: :ok
  def answer(host, answer) do
    Process.put({:answer, host}, answer)
    :ok
  end

  @doc "Registers the answer of the resolver for a host."
  @spec resolve(String.t(), term()) :: :ok
  def resolve(host, result) do
    Process.put({:dns, host}, result)
    :ok
  end

  @doc "An HTTP answer of the transport."
  @spec response(non_neg_integer(), binary()) :: {:ok, map()}
  def response(status, body \\ ""),
    do: {:ok, %{status: status, headers: [], body: body, truncated: false}}

  @doc "The value of a request header, or `nil`."
  @spec header(map(), String.t()) :: String.t() | nil
  def header(%{headers: headers}, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  @doc "A caller's token cache that keeps what was fetched in the test process and tells the test the lifetime."
  @spec cache((-> term())) :: {:ok, term()} | {:error, map()}
  def cache(fetch) do
    case Process.get(:cached_token) do
      nil -> fetched(fetch.())
      token -> {:ok, token}
    end
  end

  defp fetched({:ok, token, lifetime}) do
    Process.put(:cached_token, token)
    send(self(), {:cached, lifetime})
    {:ok, token}
  end

  defp fetched({:error, failure}), do: {:error, failure}
end
