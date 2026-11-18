defmodule EsuissRelay.ConformanceTest do
  use ExUnit.Case, async: true

  alias EsuissRelay.Api
  alias EsuissRelay.Client
  alias EsuissRelay.Error
  alias EsuissRelay.Generated.ErrorCatalog
  alias EsuissRelay.Operation
  alias EsuissRelay.Response
  alias EsuissRelay.Stub
  alias EsuissRelay.Webhook

  @dir "../../conformance/sdk/vectors/1"

  for name <- ~w(errors retry idempotency pagination webhooks) do
    @external_resource Path.join(@dir, name <> ".json")
  end

  @signatures "../../conformance/webhooks/vectors/1/signature.json"
              |> File.read!()
              |> JSON.decode!()

  defp vectors(name), do: @dir |> Path.join(name <> ".json") |> File.read!() |> JSON.decode!()

  defp body(nil), do: ""
  defp body(text) when is_binary(text), do: text
  defp body(json), do: JSON.encode!(json)

  defp response(%{"network_error" => true}), do: {:error, :network_error}

  defp response(%{"status" => status} = vector) do
    headers = vector |> Map.get("headers", %{}) |> Kernel.||(%{}) |> Map.to_list()
    {:ok, %{status: status, headers: headers, body: body(vector["body"])}}
  end

  defp unix(iso) do
    {:ok, datetime, 0} = DateTime.from_iso8601(iso)
    DateTime.to_unix(datetime)
  end

  test "X-29: every error vector maps to its class, code, status and retryable" do
    for vector <- vectors("errors")["cases"] do
      {:ok, transport} = response(vector["response"])
      error = Error.from_transport(transport, 0)
      expect = vector["expect"]
      name = vector["name"]

      assert Atom.to_string(error.category) == expect["class"], name
      assert error.code == expect["code"], name
      assert error.status == expect["status"], name
      assert error.retryable == expect["retryable"], name
      assert is_exception(error)

      if expect["request_id"], do: assert(error.request_id == expect["request_id"], name)
      if expect["retry_after_s"], do: assert(error.retry_after == expect["retry_after_s"], name)

      if expect["field_errors"],
        do: assert(length(error.problem["errors"]) == expect["field_errors"])
    end
  end

  test "API-38: the generated catalog and status defaults match the error vectors" do
    vectors = vectors("errors")

    assert map_size(ErrorCatalog.codes()) == length(vectors["catalog"])

    for entry <- vectors["catalog"] do
      assert %{family: family, status: status, retryable: retryable} =
               ErrorCatalog.lookup(entry["code"])

      assert {family, status, retryable} == {entry["family"], entry["status"], entry["retryable"]}
      assert Atom.to_string(Error.category(status, entry["code"])) == entry["class"]
    end

    for entry <- vectors["status_defaults"] do
      assert ErrorCatalog.default_retryable(entry["status"], entry["code"]) == entry["retryable"]
    end
  end

  test "X-29: the backoff vectors give full jitter under the exponential ceiling" do
    vectors = vectors("retry")
    policy = vectors["policy"]

    for entry <- vectors["backoff"] do
      {client, _stub} =
        Stub.client([],
          random: fn -> entry["random"] end,
          max_retries: policy["max_retries"],
          base_delay_ms: policy["base_ms"],
          max_delay_ms: policy["cap_ms"],
          max_retry_after_s: policy["max_retry_after_s"]
        )

      assert {:retry, wait} = Client.retry_decision(client, entry["retry"], 100, :network_error)
      assert wait == entry["delay_ms"]
      assert wait >= entry["min_ms"] and wait <= entry["max_ms"]
    end
  end

  test "X-29: every retry decision vector retries or stops as published" do
    vectors = vectors("retry")
    policy = vectors["policy"]

    for vector <- vectors["decisions"] do
      {client, _stub} =
        Stub.client([],
          random: fn -> vector["random"] end,
          clock: fn -> unix(vector["now"]) end
        )

      assert client.max_retries == policy["max_retries"]
      assert client.base_delay_ms == policy["base_ms"]
      assert client.max_delay_ms == policy["cap_ms"]
      assert client.max_retry_after_s == policy["max_retry_after_s"]

      outcome =
        case response(Map.get(vector, "response", vector)) do
          {:error, :network_error} -> :network_error
          {:ok, transport} -> {:response, transport}
        end

      decision = Client.retry_decision(client, vector["retry"], policy["max_retries"], outcome)

      case vector["expect"] do
        %{"retry" => true, "delay_ms" => delay} ->
          assert decision == {:retry, delay}, vector["name"]

        %{"retry" => false, "reason" => reason} ->
          assert {:stop, stopped} = decision
          assert Atom.to_string(stopped) == reason, vector["name"]
      end
    end
  end

  defp method("GET"), do: :get
  defp method("POST"), do: :post
  defp method("PUT"), do: :put
  defp method("PATCH"), do: :patch
  defp method("DELETE"), do: :delete

  defp operation(call) do
    %Operation{
      id: :vector,
      method: method(call["method"]),
      path: call["path"],
      idempotency: if(call["takes_idempotency_key"], do: :required, else: :none),
      body: if(call["method"] == "GET", do: :none, else: :optional),
      content_type: "application/json"
    }
  end

  defp run_call(call) do
    {client, stub} = Stub.client(Enum.map(call["responses"], &response/1))

    opts =
      if call["caller_idempotency"], do: [idempotency_key: call["caller_idempotency"]], else: []

    result = Client.call(client, operation(call), [], nil, [{:raw, true} | opts])
    keys = stub |> Stub.requests() |> Enum.map(&Client.header(&1.headers, "idempotency-key"))
    {result, keys}
  end

  test "API-10: every idempotency vector sends, keeps and reports the key as published" do
    for vector <- vectors("idempotency")["cases"] do
      runs = Enum.map(vector["calls"], &run_call/1)

      for {call, {result, keys}} <- Enum.zip(vector["calls"], runs) do
        expect = call["expect"]
        name = vector["name"]

        assert length(keys) == expect["requests"], name

        if expect["key_sent"] do
          assert Enum.all?(keys, &(is_binary(&1) and byte_size(&1) in 8..255)), name
          assert length(Enum.uniq(keys)) == 1, name
        else
          assert Enum.all?(keys, &is_nil/1), name
        end

        if expect["sent_idempotency"], do: assert(hd(keys) == expect["sent_idempotency"], name)

        case expect["outcome"] do
          "success" ->
            assert {:ok, %Response{replayed: replayed}} = result
            assert replayed == expect["replayed"], name

          "error" ->
            assert {:error, error} = result
            assert Atom.to_string(error.category) == expect["error_class"], name
            assert error.code == expect["error_code"], name
        end
      end

      if vector["distinct_keys_across_calls"] do
        firsts = Enum.map(runs, fn {_result, keys} -> hd(keys) end)
        assert length(Enum.uniq(firsts)) == length(firsts)
      end
    end
  end

  @page_params %{
    "limit" => :limit,
    "starting_after" => :starting_after,
    "ending_before" => :ending_before
  }

  defp page_opts(params),
    do: Enum.map(params, fn {key, value} -> {Map.fetch!(@page_params, key), value} end)

  test "API-56: every pagination vector reads lazily in its direction with the published queries" do
    vectors = vectors("pagination")

    for vector <- vectors["cases"] do
      pages = Enum.map(vector["exchanges"], &Stub.json(200, &1["page"]))
      {client, stub} = Stub.client(pages)

      assert {:ok, page} = Api.list_notifications(client, page_opts(vector["params"]))

      items = if vector["take"], do: Enum.take(page, vector["take"]), else: Enum.to_list(page)
      assert Enum.map(items, & &1["id"]) == vector["expect"]["items"], vector["name"]

      requests = Stub.requests(stub)
      assert length(requests) == vector["expect"]["requests"], vector["name"]

      for {request, exchange} <- Enum.zip(requests, vector["exchanges"]) do
        query = URI.parse(request.url).query || ""
        assert URI.decode_query(query) == exchange["query"], vector["name"]
      end
    end

    for rejection <- vectors["rejections"] do
      {client, stub} = Stub.client([])

      assert_raise ArgumentError, ~r/both_cursors/, fn ->
        Api.list_notifications(client, page_opts(rejection["params"]))
      end

      assert Stub.requests(stub) == []
    end
  end

  test "WH-7: every webhook header vector is accepted or refused as published" do
    for vector <- vectors("webhooks")["cases"] do
      base = Enum.find(@signatures["cases"], &(&1["name"] == vector["base"]))

      headers =
        Enum.reduce(
          vector["headers"],
          %{
            "webhook-id" => base["webhook_id"],
            "webhook-timestamp" => Integer.to_string(base["webhook_timestamp"])
          },
          fn
            {name, nil}, acc ->
              Map.delete(acc, name)

            {name, value}, acc ->
              Map.put(
                acc,
                name,
                value
                |> String.replace("{v1a}", base["v1a"])
                |> String.replace("{v1}", base["v1"])
              )
          end
        )

      keys = Enum.map(vector["keys"], &@signatures["keys"][&1])
      raw = Base.decode16!(vector["body_hex"] || base["body_hex"], case: :lower)
      now = vector["now"] || base["webhook_timestamp"]
      result = Webhook.verify(headers, raw, keys, now: now, tolerance: @signatures["tolerance_s"])

      case vector["expect"] do
        %{"ok" => true, "scheme" => scheme} ->
          assert {:ok, %{scheme: found}} = result
          assert Atom.to_string(found) == scheme, vector["name"]

        %{"ok" => false, "error" => reason} ->
          assert {:error, found} = result
          assert Atom.to_string(found) == reason, vector["name"]
      end
    end
  end
end
