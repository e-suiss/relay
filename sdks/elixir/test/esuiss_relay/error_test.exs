defmodule EsuissRelay.ErrorTest do
  use ExUnit.Case, async: true

  alias EsuissRelay.Error
  alias EsuissRelay.Generated.ErrorCatalog

  @catalog "../../contracts/errors.yaml" |> File.read!()

  test "X-29: every error answer maps to one class of the hierarchy" do
    cases = [
      {401, "auth_invalid_token", EsuissRelay.AuthenticationError},
      {403, "auth_insufficient_scope", EsuissRelay.AuthenticationError},
      {422, "validation_failed", EsuissRelay.ValidationError},
      {400, "malformed_request", EsuissRelay.ValidationError},
      {429, "rate_limited", EsuissRelay.RateLimitError},
      {429, "quota_exhausted", EsuissRelay.QuotaError},
      {400, "idempotency_key_missing", EsuissRelay.IdempotencyError},
      {422, "idempotency_key_reuse", EsuissRelay.IdempotencyError},
      {409, "idempotency_key_in_progress", EsuissRelay.IdempotencyError},
      {500, "internal_error", EsuissRelay.ServerError},
      {503, "service_unavailable", EsuissRelay.ServerError},
      {404, "waitpoint_not_found", EsuissRelay.NotFoundError},
      {409, "resource_conflict", EsuissRelay.ConflictError},
      {412, "precondition_failed", EsuissRelay.ConflictError}
    ]

    for {status, code, module} <- cases do
      error = Error.from_response(status, "req_1", %{"code" => code, "status" => status}, nil)
      assert %^module{status: ^status, code: ^code, request_id: "req_1"} = error
      assert is_binary(Exception.message(error))
    end

    assert Error.rate_limit?(Error.from_response(429, nil, %{"code" => "quota_exhausted"}, nil))
    refute Error.rate_limit?(Error.from_response(500, nil, %{}, nil))
  end

  test "API-38: the generated catalog carries every code of the error catalog" do
    codes = Regex.scan(~r/^  - code: ([a-z0-9_]+)$/m, @catalog, capture: :all_but_first)

    assert length(codes) > 100

    for [code] <- codes do
      assert %{status: _status, retryable: _retryable, family: _family} = ErrorCatalog.lookup(code)
    end

    assert ErrorCatalog.lookup("rate_limited").retryable
    refute ErrorCatalog.lookup("quota_exhausted").retryable
    assert ErrorCatalog.default_retryable(503, nil)
    refute ErrorCatalog.default_retryable(404, nil)
    refute ErrorCatalog.default_retryable(409, "resource_conflict")
  end

  test "API-38: the problem's own retryable member wins over the catalog" do
    assert Error.retryable?(500, %{"code" => "internal_error", "retryable" => false}) == false
    assert Error.retryable?(500, %{"code" => "internal_error"}) == true
    assert Error.retryable?(502, %{}) == false
  end
end
