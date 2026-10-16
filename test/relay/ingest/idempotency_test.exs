defmodule Relay.Ingest.IdempotencyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Ingest.Idempotency

  describe "API-11 API-13 API-14 idempotency keys" do
    test "API-11: keys of 8 to 255 characters are accepted, quoted or not" do
      assert Idempotency.parse_key("abcdefgh") == {:ok, "abcdefgh"}
      assert Idempotency.parse_key(~s("abcdefgh")) == {:ok, "abcdefgh"}

      assert Idempotency.parse_key(String.duplicate("k", 255)) ==
               {:ok, String.duplicate("k", 255)}
    end

    test "API-11: keys of 7 or 256 characters are refused with 400" do
      for key <- ["abcdefg", String.duplicate("k", 256), ~s("abcdefg"), "", nil, 12_345_678] do
        assert {:error, %Relay.Error{code: :invalid_idempotency_key, details: %{status: 400}}} =
                 Idempotency.parse_key(key)
      end
    end

    property "API-13: the fingerprint is SHA-256 of the raw body bytes" do
      check all body <- binary() do
        assert Idempotency.fingerprint(body) == :crypto.hash(:sha256, body)
        assert byte_size(Idempotency.fingerprint(body)) == 32
      end
    end

    test "API-13: a key in progress is 409 with Retry-After 1, a different body is 422" do
      assert %Relay.Error{code: :idempotency_in_progress, details: %{status: 409, retry_after: 1}} =
               Idempotency.claim_error(:in_progress)

      assert %Relay.Error{code: :idempotency_conflict, details: %{status: 422}} =
               Idempotency.claim_error(:conflict)
    end

    test "API-14: 400, 401, 403 and 429 are never stored for replay" do
      for status <- [400, 401, 403, 429], do: refute(Idempotency.cacheable?(status))

      for status <- [200, 201, 202, 207, 404, 409, 422, 500],
          do: assert(Idempotency.cacheable?(status))
    end

    test "API-11: the root module exposes the key and fingerprint readers" do
      assert Relay.Ingest.parse_idempotency_key("abcdefgh") == {:ok, "abcdefgh"}
      assert Relay.Ingest.idempotency_fingerprint("") == :crypto.hash(:sha256, "")
    end
  end
end
