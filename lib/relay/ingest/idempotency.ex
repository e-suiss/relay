defmodule Relay.Ingest.Idempotency do
  @moduledoc """
  Idempotency keys of mutating requests. The key comes from the `Idempotency-Key` header, the fingerprint is the SHA-256 of the raw body, and the scope is tenant, environment, endpoint and key. The store is PostgreSQL; the first transaction to claim a key wins.
  """

  @not_cacheable [400, 401, 403, 429]

  @type key :: String.t()
  @type claim :: :created | :replayed | :in_progress | :conflict

  # API-10
  # API-11
  @doc "Reads an idempotency key from its header value, quoted or not; it must be 8 to 255 characters."
  @spec parse_key(term()) :: {:ok, key()} | {:error, Relay.Error.t()}
  def parse_key(value) when is_binary(value) do
    key =
      case value do
        <<?", rest::binary>> -> String.trim_trailing(rest, "\"")
        _ -> value
      end

    if String.valid?(key) and String.length(key) in 8..255,
      do: {:ok, key},
      else: invalid_key()
  end

  def parse_key(_value), do: invalid_key()

  # API-13
  @doc "Returns the request fingerprint: SHA-256 of the raw body bytes."
  @spec fingerprint(iodata()) :: <<_::256>>
  def fingerprint(raw_body), do: :crypto.hash(:sha256, raw_body)

  # API-14
  @doc "Returns true if a response with this status is stored for replay."
  @spec cacheable?(100..599) :: boolean()
  def cacheable?(status) when is_integer(status), do: status not in @not_cacheable

  # API-13
  @doc "Returns the error a claim that cannot proceed maps to: 409 with `Retry-After: 1` while in progress, 422 for a different body."
  @spec claim_error(:in_progress | :conflict) :: Relay.Error.t()
  def claim_error(:in_progress),
    do:
      Relay.Error.new(:idempotency_in_progress, "a request with this key is in progress", %{
        status: 409,
        retry_after: 1
      })

  def claim_error(:conflict),
    do:
      Relay.Error.new(:idempotency_conflict, "this key was used with a different body", %{
        status: 422
      })

  defp invalid_key,
    do:
      {:error,
       Relay.Error.new(:invalid_idempotency_key, "the key must be 8 to 255 characters", %{
         status: 400
       })}
end
