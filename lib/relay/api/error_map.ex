defmodule Relay.Api.ErrorMap do
  @moduledoc """
  The single table from internal errors to API error codes. A code that is already in the catalog passes through; the stage-1 idempotency codes, an inactive tenant and every failure to write durably have their API names; any other internal error is `internal_error`, whose detail never carries the internal message.
  """

  alias Relay.Api.ErrorCatalog

  @renamed %{
    idempotency_in_progress: :idempotency_key_in_progress,
    idempotency_conflict: :idempotency_key_reuse,
    invalid_idempotency_key: :idempotency_key_invalid,
    tenant_inactive: :auth_tenant_suspended
  }

  @unavailable [
    :database_unreachable,
    :database_error,
    :accept_failed,
    :limiter_unavailable,
    :not_ready,
    :key_store_unavailable
  ]

  # API-40
  # INV-2
  @doc "Maps an error to the API error it is answered with."
  @spec to_api(Relay.Error.t()) :: Relay.Error.t()
  def to_api(%Relay.Error{code: code} = error) do
    cond do
      Map.has_key?(@renamed, code) ->
        %{error | code: Map.fetch!(@renamed, code), details: %{}}

      code in @unavailable ->
        Relay.Error.new(:service_unavailable, "the request could not be recorded durably")

      ErrorCatalog.fetch(code) != :error ->
        error

      true ->
        Relay.Error.new(:internal_error, "an unexpected error occurred")
    end
  end
end
