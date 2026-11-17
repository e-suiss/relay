defmodule EsuissRelay.ClientTest do
  use ExUnit.Case, async: true

  alias EsuissRelay.Api
  alias EsuissRelay.Client
  alias EsuissRelay.Stub

  @waitpoint %{"object" => "waitpoint", "id" => "wp_1", "state" => "open"}

  defp problem(status, code, extra \\ %{}) do
    Map.merge(
      %{"type" => "https://relay.test/v1/errors/#{code}", "title" => code, "status" => status, "code" => code},
      extra
    )
  end

  defp header(request, name), do: Client.header(request.headers, name)

  test "API-55: every request carries the pinned API version, DPoP credentials and a user agent" do
    {client, stub} = Stub.client([Stub.json(200, @waitpoint)])

    assert {:ok, @waitpoint} = Api.get_waitpoint(client, "wp_1")
    [request] = Stub.requests(stub)

    assert request.method == :get
    assert request.url == "https://relay.test/v1/waitpoints/wp_1"
    assert header(request, "relay-version") == EsuissRelay.api_version()
    assert header(request, "authorization") == "DPoP token-1"
    assert header(request, "dpop") =~ ~r/\A[\w-]+\.[\w-]+\.[\w-]+\z/
    assert header(request, "user-agent") =~ "esuiss-relay-elixir/"
    assert header(request, "idempotency-key") == nil
    assert request.body == nil
  end

  test "API-10: a mutating call gets one idempotency key that every retry repeats" do
    responses = [
      Stub.json(503, problem(503, "service_unavailable", %{"retryable" => true})),
      {:error, :timeout},
      Stub.json(201, @waitpoint)
    ]

    {client, stub} = Stub.client(responses)

    assert {:ok, @waitpoint} = Api.create_waitpoint(client, %{"kind" => "event"})
    keys = stub |> Stub.requests() |> Enum.map(&header(&1, "idempotency-key"))

    assert [key, key, key] = keys
    assert key =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    proofs = stub |> Stub.requests() |> Enum.map(&header(&1, "dpop"))
    assert length(Enum.uniq(proofs)) == 3
  end

  test "API-10: a caller's own idempotency key is sent unchanged" do
    {client, stub} = Stub.client([Stub.json(201, @waitpoint)])

    assert {:ok, _waitpoint} = Api.create_waitpoint(client, %{}, idempotency_key: "order-4821-key")
    assert [request] = Stub.requests(stub)
    assert header(request, "idempotency-key") == "order-4821-key"
    assert header(request, "content-type") == "application/json"
    assert JSON.decode!(request.body) == %{}
  end

  test "X-29: an error Relay marks not retryable is returned at once" do
    {client, stub} = Stub.client([Stub.json(422, problem(422, "validation_failed", %{"retryable" => false}))])

    assert {:error, %EsuissRelay.ValidationError{code: "validation_failed", retryable: false}} =
             Api.create_waitpoint(client, %{})

    assert length(Stub.requests(stub)) == 1
    refute_received {:slept, _ms}
  end

  test "X-29: Retry-After decides the wait when it is given" do
    responses = [
      Stub.json(429, problem(429, "rate_limited", %{"retryable" => true}), [{"Retry-After", "7"}]),
      Stub.json(200, @waitpoint)
    ]

    {client, _stub} = Stub.client(responses)

    assert {:ok, @waitpoint} = Api.get_waitpoint(client, "wp_1")
    assert_received {:slept, 7000}
  end

  test "X-29: without Retry-After the wait is full jitter under an exponential ceiling" do
    retryable = Stub.json(500, problem(500, "internal_error", %{"retryable" => true}))
    {client, stub} = Stub.client([retryable, retryable, retryable, retryable])

    assert {:error, %EsuissRelay.ServerError{status: 500}} = Api.get_waitpoint(client, "wp_1")
    assert length(Stub.requests(stub)) == 4
    assert_received {:slept, 500}
    assert_received {:slept, 1000}
    assert_received {:slept, 2000}

    client = %{client | max_delay_ms: 1500}
    assert Client.delay(client, 5, 10, true, nil) == 1500

    client = %{client | random: &Client.uniform/1}

    for _round <- 1..200 do
      assert Client.delay(client, 2, 10, true, nil) in 0..1500
    end
  end

  test "X-29: a Retry-After longer than the client waits is not waited for" do
    response = Stub.json(503, problem(503, "service_unavailable", %{"retryable" => true}), [{"retry-after", "3600"}])
    {client, stub} = Stub.client([response])

    assert {:error, %EsuissRelay.ServerError{retry_after: 3600}} = Api.get_waitpoint(client, "wp_1")
    assert length(Stub.requests(stub)) == 1
  end

  test "API-38: without a retryable member the catalog and the status table decide" do
    in_progress = Stub.json(409, %{"code" => "idempotency_key_in_progress"}, [{"retry-after", "1"}])
    {client, stub} = Stub.client([in_progress, Stub.json(201, @waitpoint)])

    assert {:ok, _waitpoint} = Api.create_waitpoint(client, %{})
    assert length(Stub.requests(stub)) == 2

    {client, stub} = Stub.client([Stub.json(429, %{"code" => "quota_exhausted"})])
    assert {:error, %EsuissRelay.QuotaError{retryable: false}} = Api.create_waitpoint(client, %{})
    assert length(Stub.requests(stub)) == 1

    {client, stub} = Stub.client([{:ok, %{status: 504, headers: [], body: "gateway"}}, Stub.json(200, @waitpoint)])
    assert {:ok, _waitpoint} = Api.get_waitpoint(client, "wp_1")
    assert length(Stub.requests(stub)) == 2
  end

  test "X-29: a request that got no answer is retried only when it is safe to repeat" do
    {client, stub} = Stub.client([{:error, :econnrefused}, Stub.json(200, @waitpoint)])
    assert {:ok, _waitpoint} = Api.get_waitpoint(client, "wp_1")
    assert length(Stub.requests(stub)) == 2

    {client, stub} = Stub.client([{:error, :closed}, {:error, :closed}], max_retries: 1)

    assert {:error, %EsuissRelay.ConnectionError{reason: :closed}} =
             Api.create_waitpoint(client, %{})

    assert length(Stub.requests(stub)) == 2

    {client, stub} = Stub.client([{:error, :closed}, Stub.json(202, %{})])

    assert {:error, %EsuissRelay.ConnectionError{}} =
             Api.publish_ag_ui_event(client, %{"recipient_id" => "sub_1", "payload" => "x"})

    assert length(Stub.requests(stub)) == 1
  end

  test "X-29: path, query and header options are encoded from the operation" do
    {client, stub} = Stub.client([Stub.json(200, %{"id" => "ntf_1"})])

    assert {:ok, _notification} =
             Api.get_notification(client, "ntf 1/x", expand: ["deliveries"], beta: ["a", "b"])

    [request] = Stub.requests(stub)
    assert request.url == "https://relay.test/v1/notifications/ntf%201%2Fx?expand=deliveries"
    assert header(request, "relay-beta") == "a,b"

    assert_raise ArgumentError, fn -> Api.get_waitpoint(client, "wp_1", colour: "red") end
    assert_raise ArgumentError, fn -> Api.update_subscriber(client, "sub_1", %{}) end
  end

  test "X-29: the base URL must be https" do
    assert_raise ArgumentError, fn ->
      Client.new(base_url: "http://relay.example.com", credentials: nil)
    end
  end
end
