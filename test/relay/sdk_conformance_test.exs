defmodule Relay.SdkConformanceTest do
  use ExUnit.Case, async: true

  alias Relay.Webhooks.Profile

  @dir "conformance/sdk/vectors/1"
  @schema "conformance/sdk/vectors.schema.json" |> File.read!() |> Jason.decode!()
  @errors "#{@dir}/errors.json" |> File.read!() |> Jason.decode!()
  @retry "#{@dir}/retry.json" |> File.read!() |> Jason.decode!()
  @idempotency "#{@dir}/idempotency.json" |> File.read!() |> Jason.decode!()
  @pagination "#{@dir}/pagination.json" |> File.read!() |> Jason.decode!()
  @webhooks "#{@dir}/webhooks.json" |> File.read!() |> Jason.decode!()
  @catalog YamlElixir.read_from_file!("contracts/errors.yaml")
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp catalog_entry(code), do: Enum.find(@errors["catalog"], &(&1["code"] == code))

  defp class_of(%{"family" => family, "status" => status}) do
    case Map.fetch(@errors["family_classes"], family) do
      {:ok, class} -> class
      :error when status >= 500 -> "server"
      :error -> "validation"
    end
  end

  defp fallback_class(status) do
    Enum.find_value(@errors["fallback"], fn rule ->
      if status >= rule["status_min"] and status <= rule["status_max"], do: rule["class"]
    end)
  end

  defp problem(%{"body" => %{"code" => code, "retryable" => retryable}}), do: {code, retryable}

  defp problem(_response), do: nil

  defp default_retryable(status) do
    Enum.any?(@errors["status_defaults"], fn entry ->
      entry["status"] == status and entry["code"] == nil and entry["retryable"]
    end)
  end

  defp classify(response) do
    case problem(response) do
      {code, retryable} ->
        class =
          case catalog_entry(code) do
            nil -> fallback_class(response["status"])
            entry -> class_of(entry)
          end

        %{class: class, code: code, retryable: retryable}

      nil ->
        %{
          class: fallback_class(response["status"]),
          code: nil,
          retryable: default_retryable(response["status"])
        }
    end
  end

  defp retryable?(%{"network_error" => true}), do: true
  defp retryable?(response), do: classify(response).retryable

  defp backoff(retry, random) do
    policy = @retry["policy"]
    ceiling = min(policy["cap_ms"], policy["base_ms"] * Integer.pow(2, retry - 1))
    floor(random * ceiling)
  end

  defp http_date(text, now) do
    case Regex.run(~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}:\d{2}:\d{2}) GMT$/, text) do
      [_, day, month, year, time] ->
        month = Enum.find_index(@months, &(&1 == month)) + 1
        date = Date.new!(String.to_integer(year), month, String.to_integer(day))
        at = DateTime.new!(date, Time.from_iso8601!(time), "Etc/UTC")
        {:ok, max(0, DateTime.diff(at, now, :millisecond))}

      nil ->
        :error
    end
  end

  defp retry_after(response, now) do
    header = get_in(response, ["headers", "retry-after"])
    body = response["body"]

    with :error <- header_retry_after(header, now) do
      if is_map(body) and is_integer(body["retry_after"]),
        do: {:ok, body["retry_after"] * 1000},
        else: :error
    end
  end

  defp header_retry_after(nil, _now), do: :error

  defp header_retry_after(header, now) do
    if Regex.match?(~r/^[0-9]+$/, header),
      do: {:ok, String.to_integer(header) * 1000},
      else: http_date(header, now)
  end

  defp decide(%{"retry" => retry, "random" => random, "now" => now} = decision) do
    {:ok, now, 0} = DateTime.from_iso8601(now)
    response = Map.get(decision, "response", %{"network_error" => true})
    policy = @retry["policy"]
    limit_ms = policy["max_retry_after_s"] * 1000

    cond do
      not retryable?(response) ->
        %{"retry" => false, "reason" => "not_retryable"}

      retry > policy["max_retries"] ->
        %{"retry" => false, "reason" => "retries_exhausted"}

      true ->
        case retry_after(response, now) do
          {:ok, ms} when ms > limit_ms ->
            %{"retry" => false, "reason" => "retry_after_too_long"}

          {:ok, ms} ->
            %{"retry" => true, "delay_ms" => ms}

          :error ->
            %{"retry" => true, "delay_ms" => backoff(retry, random)}
        end
    end
  end

  defp run_call(call) do
    responses = call["responses"]
    max_retries = @retry["policy"]["max_retries"]

    Enum.reduce_while(Enum.with_index(responses, 1), nil, fn {response, attempt}, _acc ->
      cond do
        response["status"] in 200..299 ->
          replayed = get_in(response, ["headers", "idempotency-replayed"]) == "true"
          {:halt, %{"requests" => attempt, "outcome" => "success", "replayed" => replayed}}

        retryable?(response) and attempt <= max_retries and attempt < length(responses) ->
          {:cont, nil}

        true ->
          %{class: class, code: code} = classify(response)

          {:halt,
           %{
             "requests" => attempt,
             "outcome" => "error",
             "error_class" => class,
             "error_code" => code
           }}
      end
    end)
  end

  defp walk(%{"params" => params, "exchanges" => exchanges} = vector) do
    backward? = Map.has_key?(params, "ending_before")
    take = Map.get(vector, "take", :infinity)
    first = for {key, value} <- params, into: %{}, do: {key, to_string(value)}
    walk(exchanges, first, backward?, take, [], 0)
  end

  defp walk(_exchanges, nil, _backward?, _take, items, requests), do: {items, requests}

  defp walk(_exchanges, _query, _backward?, take, items, requests)
       when is_integer(take) and length(items) >= take,
       do: {Enum.take(items, take), requests}

  defp walk([exchange | rest], query, backward?, take, items, requests) do
    assert exchange["query"] == query
    page = exchange["page"]
    data = Enum.map(page["data"], & &1["id"])
    {data, cursor, param} = step(page, data, backward?)
    walk(rest, next_query(query, cursor, param), backward?, take, items ++ data, requests + 1)
  end

  defp next_query(_query, nil, _param), do: nil

  defp next_query(query, cursor, param),
    do: query |> Map.drop(["starting_after", "ending_before"]) |> Map.put(param, cursor)

  defp step(page, data, true), do: {Enum.reverse(data), page["previous_cursor"], "ending_before"}
  defp step(page, data, false), do: {data, page["next_cursor"], "starting_after"}

  defp signature_vectors do
    @webhooks["signatures"] |> File.read!() |> Jason.decode!()
  end

  defp webhook_key(signatures, name) do
    {:ok, key} = Profile.parse_key(signatures["keys"][name])
    key
  end

  defp webhook_headers(base, overrides) do
    defaults = %{
      "webhook-id" => base["webhook_id"],
      "webhook-timestamp" => Integer.to_string(base["webhook_timestamp"]),
      "webhook-signature" => nil
    }

    defaults
    |> Map.merge(overrides)
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Enum.map(fn {name, value} ->
      {name, value |> String.replace("{v1a}", base["v1a"]) |> String.replace("{v1}", base["v1"])}
    end)
  end

  describe "X-29 SDK conformance vectors" do
    test "X-29: every SDK vector file matches the vector schema" do
      root = JSV.build!(@schema, default_meta: "https://json-schema.org/draft/2020-12/schema")
      files = Path.wildcard("#{@dir}/*.json")
      assert length(files) == 5

      for path <- files do
        content = path |> File.read!() |> Jason.decode!()
        assert {:ok, _content} = JSV.validate(content, root, cast: false), path
      end
    end

    test "X-29: the error vector catalog is contracts/errors.yaml, code by code" do
      expected =
        for entry <- @catalog["codes"] do
          %{
            "code" => entry["code"],
            "family" => entry["family"],
            "status" => entry["status"],
            "retryable" => entry["retryable"],
            "retry_after" => entry["retry_after"]
          }
        end

      actual = Enum.map(@errors["catalog"], &Map.delete(&1, "class"))
      assert actual == expected
    end

    test "X-29: the class of every catalog code follows its family" do
      for entry <- @errors["catalog"] do
        assert entry["class"] == class_of(entry), entry["code"]
        assert entry["class"] in @errors["classes"]
      end

      assert Enum.sort(@errors["classes"]) ==
               Enum.sort(~w(auth validation rate_limit idempotency server))
    end

    test "API-38: the vector status defaults are the catalog's retryable defaults" do
      assert @errors["status_defaults"] == @catalog["retryable_defaults"]
    end

    test "X-29: classification cases agree with the catalog and the status defaults" do
      for %{"response" => response, "expect" => expect} = vector <- @errors["cases"] do
        result = classify(response)
        assert result.class == expect["class"], vector["name"]
        assert result.code == expect["code"], vector["name"]
        assert result.retryable == expect["retryable"], vector["name"]
        assert response["status"] == expect["status"], vector["name"]
      end
    end

    test "X-29: backoff vectors are full jitter within the policy bounds" do
      policy = @retry["policy"]

      for vector <- @retry["backoff"] do
        ceiling = min(policy["cap_ms"], policy["base_ms"] * Integer.pow(2, vector["retry"] - 1))
        assert vector["max_ms"] == ceiling
        assert vector["min_ms"] == 0
        assert vector["delay_ms"] == backoff(vector["retry"], vector["random"])
        assert vector["delay_ms"] >= 0 and vector["delay_ms"] < max(ceiling, 1)
      end
    end

    test "X-29: retry decisions retry only retryable errors and honour Retry-After" do
      for vector <- @retry["decisions"] do
        assert decide(vector) == vector["expect"], vector["name"]
      end
    end

    test "API-10: idempotency cases keep one key per call and stop on non-retryable errors" do
      for %{"calls" => calls} = vector <- @idempotency["cases"], call <- calls do
        result = run_call(call)
        expect = call["expect"]
        assert result["requests"] == expect["requests"], vector["name"]
        assert result["outcome"] == expect["outcome"], vector["name"]

        for field <- ~w(replayed error_class error_code), Map.has_key?(expect, field) do
          assert result[field] == expect[field], "#{vector["name"]} #{field}"
        end

        assert expect["key_sent"] == call["takes_idempotency_key"], vector["name"]
      end
    end

    test "API-56: pagination cases walk the cursors lazily in both directions" do
      for vector <- @pagination["cases"] do
        {items, requests} = walk(vector)
        assert items == vector["expect"]["items"], vector["name"]
        assert requests == vector["expect"]["requests"], vector["name"]
      end

      for vector <- @pagination["rejections"] do
        assert Map.has_key?(vector["params"], "starting_after")
        assert Map.has_key?(vector["params"], "ending_before")
      end
    end

    test "WH-4: webhook header cases agree with the server verifier" do
      signatures = signature_vectors()
      tolerance = signatures["tolerance_s"]

      for vector <- @webhooks["cases"] do
        base = Enum.find(signatures["cases"], &(&1["name"] == vector["base"]))
        keys = Enum.map(vector["keys"], &webhook_key(signatures, &1))
        body = Base.decode16!(Map.get(vector, "body_hex", base["body_hex"]), case: :lower)
        now = DateTime.from_unix!(Map.get(vector, "now", base["webhook_timestamp"]))
        headers = webhook_headers(base, vector["headers"])

        expected =
          case vector["expect"] do
            %{"ok" => true, "scheme" => scheme} -> {:ok, scheme}
            %{"ok" => false, "error" => error} -> {:error, error}
          end

        result =
          case Profile.verify(headers, body, keys, now, tolerance) do
            {:ok, %{scheme: scheme}} -> {:ok, Atom.to_string(scheme)}
            {:error, reason} -> {:error, Atom.to_string(reason)}
          end

        assert result == expected, vector["name"]
      end
    end
  end
end
