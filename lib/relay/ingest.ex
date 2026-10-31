defmodule Relay.Ingest do
  @moduledoc """
  Event intake, idempotency and deduplication. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Ingest.Accept
  alias Relay.Ingest.Idempotency
  alias Relay.Ingest.Store

  # OP-7
  # INV-2
  @doc "Accepts notifications in one transaction; see `Relay.Ingest.Accept`."
  @spec accept(Relay.Scope.t(), map()) ::
          {:ok, Accept.outcome() | Accept.replay()} | {:error, Relay.Error.t()}
  defdelegate accept(scope, request), to: Accept, as: :run

  # API-11
  @doc "Reads an `Idempotency-Key` header value."
  @spec parse_idempotency_key(term()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  defdelegate parse_idempotency_key(value), to: Idempotency, as: :parse_key

  # API-13
  @doc "Returns the SHA-256 fingerprint of a raw request body."
  @spec idempotency_fingerprint(iodata()) :: <<_::256>>
  defdelegate idempotency_fingerprint(raw_body), to: Idempotency, as: :fingerprint

  # API-14
  @doc "Returns true if a response with this status is stored for replay."
  @spec idempotency_cacheable?(100..599) :: boolean()
  defdelegate idempotency_cacheable?(status), to: Idempotency, as: :cacheable?

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`, the transaction an idempotent request runs in."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  defdelegate in_scope(scope, fun), to: Store

  # API-11
  # API-13
  # API-15
  @doc "Claims an idempotency key inside the caller's scoped transaction; see `Relay.Ingest.Store.idempotency_begin/3`."
  @spec idempotency_begin(String.t(), String.t(), <<_::256>>) ::
          {:created | :in_progress | :conflict, nil} | {:replayed, Store.response()}
  defdelegate idempotency_begin(endpoint, key, fingerprint), to: Store

  # API-14
  @doc "Stores the response of a key claimed in the same transaction; see `Relay.Ingest.Store.idempotency_complete/4`."
  @spec idempotency_complete(String.t(), String.t(), <<_::256>>, Store.response()) ::
          :stored | :not_cacheable | :not_claimed
  defdelegate idempotency_complete(endpoint, key, fingerprint, response), to: Store
end
