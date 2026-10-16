defmodule Relay.Ingest do
  @moduledoc """
  Event intake, idempotency and deduplication. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Ingest.Accept
  alias Relay.Ingest.Idempotency

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
end
