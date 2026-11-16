defmodule Relay.Webhooks.Destination.AzureEventGridTest do
  use ExUnit.Case, async: true

  import RelayTest.DestinationFixture

  alias Relay.Redacted
  alias Relay.Webhooks.Destination.AzureEventGrid
  alias Relay.Webhooks.Outcome

  @host "orders.westeurope-1.eventgrid.azure.net"
  @endpoint "https://orders.westeurope-1.eventgrid.azure.net/api/events"
  @client_id "6f1c5a2e-58a1-4d0f-9d4b-0f6f4c7f3b11"

  defp config(extra \\ %{}),
    do: Map.merge(%{endpoint: @endpoint, credential: Redacted.wrap("grid-access-value")}, extra)

  defp identity(client_id, resource) do
    send(self(), {:identity, client_id, resource})
    {:ok, Redacted.wrap("bearer-1")}
  end

  describe "WH-18 success" do
    test "WH-18: the 2xx answer of the topic is the acknowledged write" do
      message = prepared()

      assert {:ok, receipt} = AzureEventGrid.deliver(config(), message, options())
      assert %{kind: :write, status: 200, address: "203.0.114.10"} = receipt
      assert %Outcome{result: :delivered} = Outcome.classify({:ok, receipt}, now())

      assert_received {:sent, %{host: @host, port: 443}, request}
      assert %{method: "POST", path: "/api/events?api-version=2018-01-01"} = request
      assert request.body == message.body
      refute_received {:sent, _connection, _request}
    end

    test "WH-17: an endpoint that names its own API version is called as it is" do
      endpoint = "https://ns.westeurope-1.eventgrid.azure.net/topics/orders:publish"
      config = config(%{endpoint: endpoint <> "?api-version=2023-11-01"})

      assert {:ok, _receipt} = AzureEventGrid.deliver(config, prepared(), options())
      assert_received {:sent, _connection, request}
      assert request.path == "/topics/orders:publish?api-version=2023-11-01"
    end
  end

  describe "WH-8 CloudEvents mode" do
    test "WH-8: the event travels in structured mode with the id inside" do
      assert {:ok, _receipt} = AzureEventGrid.deliver(config(), prepared(), options())
      assert_received {:sent, _connection, request}

      assert header(request, "content-type") == "application/cloudevents+json; charset=utf-8"
      assert %{"specversion" => "1.0", "id" => "evt_1"} = Jason.decode!(request.body)
      assert Jason.decode!(request.body)["subject"] == "order/o-1"
    end
  end

  describe "WH-17 authentication" do
    test "WH-17: the access key is sent in aeg-sas-key" do
      assert {:ok, _receipt} = AzureEventGrid.deliver(config(), prepared(), options())
      assert_received {:sent, _connection, request}

      assert header(request, "aeg-sas-key") == "grid-access-value"
      assert header(request, "authorization") == nil
    end

    test "WH-17: a managed identity sends the bearer token of the caller's function" do
      config = %{endpoint: @endpoint, managed_identity_client_id: @client_id}
      options = options(managed_identity: &identity/2)

      assert {:ok, _receipt} = AzureEventGrid.deliver(config, prepared(), options)

      assert_received {:identity, @client_id, "https://eventgrid.azure.net"}
      assert_received {:sent, _connection, request}
      assert header(request, "authorization") == "Bearer bearer-1"
      assert header(request, "aeg-sas-key") == nil
    end

    test "WH-17: without an identity function the identity is not available" do
      config = %{endpoint: @endpoint, managed_identity_client_id: @client_id}

      assert {:error, failure} = AzureEventGrid.deliver(config, prepared(), options())
      assert %{class: :credentials, reason: "managed_identity_unavailable"} = failure
      assert %Outcome{result: :retry} = Outcome.classify({:error, failure}, now())
      refute_received {:sent, _connection, _request}
    end

    test "WH-17: a destination without a usable credential or endpoint is invalid" do
      configs = [
        %{endpoint: @endpoint},
        %{endpoint: @endpoint, credential: Redacted.wrap("line\r\nbreak")},
        %{endpoint: @endpoint, credential: Redacted.wrap(nil)},
        %{credential: Redacted.wrap("grid-access-value")}
      ]

      for config <- configs do
        assert {:error, failure} = AzureEventGrid.deliver(config, prepared(), options())
        assert failure.class == :invalid
      end

      refute_received {:sent, _connection, _request}
    end
  end

  describe "WH-18 failures" do
    test "WH-18: the answers of the topic are classified" do
      cases = [
        {400, :rejected, :dead_lettered},
        {413, :rejected, :dead_lettered},
        {401, :credentials, :retry},
        {403, :credentials, :retry},
        {503, :unavailable, :retry}
      ]

      for {status, class, result} <- cases do
        answer(@host, response(status, "{}"))

        assert {:error, failure} = AzureEventGrid.deliver(config(), prepared(), options())
        assert %{class: ^class, address: "203.0.114.10"} = failure
        assert %Outcome{result: ^result} = Outcome.classify({:error, failure}, now())
      end
    end
  end

  describe "WH-43 egress rules" do
    test "WH-43: an endpoint that resolves to a blocked address is never called" do
      resolve(@host, {:ok, [{168, 63, 129, 16}]})

      assert {:error, failure} = AzureEventGrid.deliver(config(), prepared(), options())
      assert %{class: :blocked, address: "168.63.129.16"} = failure
      assert %Outcome{result: :dead_lettered} = Outcome.classify({:error, failure}, now())
      refute_received {:sent, _connection, _request}
    end

    test "WH-43: an endpoint obeys the registration rules" do
      endpoints = [
        {"http://orders.westeurope-1.eventgrid.azure.net/api/events", :invalid},
        {"https://user:pw@orders.westeurope-1.eventgrid.azure.net/api/events", :invalid},
        {"https://metadata.azure.internal/api/events", :blocked},
        {"https://127.0.0.1/api/events", :blocked}
      ]

      for {endpoint, class} <- endpoints do
        config = config(%{endpoint: endpoint})
        assert {:error, %{class: ^class}} = AzureEventGrid.deliver(config, prepared(), options())
      end

      refute_received {:sent, _connection, _request}
    end
  end

  describe "WH-19 credentials" do
    test "WH-19: the access key appears in no failure" do
      answer(@host, response(401, "denied"))

      assert {:error, failure} = AzureEventGrid.deliver(config(), prepared(), options())
      refute inspect(failure) =~ "grid-access-value"
      refute inspect(config()) =~ "grid-access-value"
    end
  end
end
