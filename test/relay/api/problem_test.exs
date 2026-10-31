defmodule Relay.Api.ProblemTest do
  use ExUnit.Case, async: true

  alias Relay.Api.Contract
  alias Relay.Api.ErrorCatalog
  alias Relay.Api.ErrorMap
  alias Relay.Api.Problem

  @context %{base_url: "https://relay.example.com", instance: "/v1/events", request_id: "req_1"}

  defp error(code), do: %Relay.Error{code: code, message: "x"}

  describe "API-36 problem documents" do
    test "API-36: a problem carries type, title, status, code, retryable, instance and request_id" do
      error = Relay.Error.new(:idempotency_key_reuse, "different body")
      {422, [], body} = Problem.build(error, @context)

      assert body["type"] == "https://relay.example.com/v1/errors/idempotency_key_reuse"
      assert body["code"] == "idempotency_key_reuse"
      {:ok, entry} = ErrorCatalog.fetch("idempotency_key_reuse")
      assert body["title"] == entry.title
      assert body["status"] == 422
      assert body["retryable"] == false
      assert body["instance"] == "/v1/events"
      assert body["request_id"] == "req_1"
      assert body["detail"] == "different body"
      refute Map.has_key?(body, "errors")
    end

    test "API-73: every problem type resolves on the region's base URL and is never about:blank" do
      for code <- ErrorCatalog.codes() do
        {_status, _headers, body} = Problem.build(error(code), @context)
        assert body["type"] == "https://relay.example.com/v1/errors/" <> code
      end
    end

    test "API-36: extensions are carried and unknown details are not" do
      error =
        Relay.Error.new(:auth_insufficient_scope, "scope", %{
          required_scope: "config",
          granted_scopes: ["read"],
          internal: :secret
        })

      {403, [], body} = Problem.build(error, @context)
      assert body["required_scope"] == "config"
      assert body["granted_scopes"] == ["read"]
      refute Map.has_key?(body, "internal")
    end
  end

  describe "API-37 field errors" do
    test "API-37: field errors are RFC 6901 pointers with subcodes" do
      error =
        Relay.Error.new(:validation_failed, "bad", %{
          errors: [
            %{pointer: "/to/0/phone", code: "invalid_format"},
            %{pointer: "/by", code: "required"}
          ]
        })

      {422, [], body} = Problem.build(error, @context)

      assert body["errors"] == [
               %{"pointer" => "/to/0/phone", "code" => "invalid_format"},
               %{"pointer" => "/by", "code" => "required"}
             ]
    end

    test "API-37: the subcodes are the catalog's" do
      assert ErrorCatalog.field_error_codes() ==
               ~w(required invalid_format too_long too_short not_found not_allowed conflict unsupported_value)
    end
  end

  describe "API-38 retryable" do
    test "API-38: every retryable problem has Retry-After equal to retry_after; no other has it" do
      for code <- ErrorCatalog.codes() do
        {status, headers, body} = Problem.build(error(code), @context)

        if body["retryable"] do
          assert [{"retry-after", seconds}] = headers
          assert String.to_integer(seconds) == body["retry_after"]
          assert body["retry_after"] > 0
        else
          assert headers == [], "#{code} (#{status}) is not retryable but sends Retry-After"
          refute Map.has_key?(body, "retry_after")
        end
      end
    end

    test "API-38: the catalog follows the status table" do
      for default <- ErrorCatalog.retryable_defaults(), code <- ErrorCatalog.codes() do
        {:ok, entry} = ErrorCatalog.fetch(code)

        if entry.status == default["status"] and default["code"] in [nil, code],
          do: assert(entry.retryable == default["retryable"], code)
      end
    end

    test "API-38: in progress waits 1 s, rate limited the remaining window, 503 at least 5 s" do
      {409, [{"retry-after", "1"}], _} =
        Problem.build(Relay.Error.new(:idempotency_key_in_progress, "x"), @context)

      {429, [{"retry-after", "17"}], %{"retry_after" => 17}} =
        Problem.build(Relay.Error.new(:rate_limited, "x", %{retry_after: 17}), @context)

      {503, [{"retry-after", "5"}], _} =
        Problem.build(Relay.Error.new(:service_unavailable, "x"), @context)
    end
  end

  describe "API-39 and API-40" do
    test "API-39: no catalog code is a 2xx" do
      for code <- ErrorCatalog.codes() do
        {:ok, entry} = ErrorCatalog.fetch(code)
        assert entry.status in 400..599, code
      end
    end

    test "API-40: internal codes map to their API names in one table" do
      assert ErrorMap.to_api(Relay.Error.new(:idempotency_in_progress, "x")).code ==
               :idempotency_key_in_progress

      assert ErrorMap.to_api(Relay.Error.new(:idempotency_conflict, "x")).code ==
               :idempotency_key_reuse

      assert ErrorMap.to_api(Relay.Error.new(:invalid_idempotency_key, "x")).code ==
               :idempotency_key_invalid

      assert ErrorMap.to_api(Relay.Error.new(:tenant_inactive, "x")).code ==
               :auth_tenant_suspended

      assert ErrorMap.to_api(Relay.Error.new(:database_unreachable, "x")).code ==
               :service_unavailable

      internal = ErrorMap.to_api(Relay.Error.new(:boom, "secret detail"))
      assert internal.code == :internal_error
      refute internal.message =~ "secret"
    end

    test "API-40: every error an operation names is in the catalog" do
      for operation <- Contract.operations(), code <- operation.errors do
        assert {:ok, _entry} = ErrorCatalog.fetch(code), "#{operation.id}: #{code}"
      end
    end
  end
end
