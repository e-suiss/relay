defmodule Relay.Api.Idempotency do
  @moduledoc """
  Idempotent execution of a mutating request (API-10 … API-15). The key is the `Idempotency-Key` header, 8 to 255 characters, quoted or not; an operation whose contract says `derived` takes a key derived from the request when the header is missing, and one that says `not_applicable` ignores the header. The scope is tenant, environment, endpoint (method and path template) and key; the fingerprint is the SHA-256 of the raw body bytes.

  The request's work runs inside the transaction that claims the key (`Relay.Ingest.idempotency_begin/3`), so a key is claimed only once its business logic starts and the stored response commits with the work or not at all. The work returns `{:ok, {status, headers, body}}` to commit and answer, or `{:error, error}` to roll back and store nothing (a failure without side effects). A response is stored, sealed under the tenant's data key, unless its status is 400, 401, 403 or 429 (API-14); the same key and body later replays it byte for byte, a different body is `idempotency_key_reuse` and a claim still in progress is `idempotency_key_in_progress`.
  """

  alias Relay.Api.Store

  @stored_headers ["content-type", "location", "etag"]

  @type response :: {100..599, [{String.t(), String.t()}], binary()}
  @type outcome :: {:fresh | :replayed, response()}
  @type mode :: :required | :derived | :not_applicable
  @type derive :: (-> {:ok, String.t()} | :none)
  @type work :: (atom() -> {:ok, response()} | {:error, Relay.Error.t()})

  # API-10
  # API-11
  @doc "Reads the idempotency key of a request for an operation's `x-relay-idempotency`; `derive` gives the key of a `derived` operation without the header, or `:none`."
  @spec key(mode(), [String.t()], derive()) :: {:ok, String.t() | nil} | {:error, Relay.Error.t()}
  def key(:not_applicable, _headers, _derive), do: {:ok, nil}

  def key(mode, [value | _], _derive) when mode in [:required, :derived], do: parse(value)

  def key(:derived, [], derive) do
    case derive.() do
      {:ok, key} -> {:ok, key}
      :none -> missing()
    end
  end

  def key(:required, [], _derive), do: missing()

  defp parse(value) do
    case Relay.Ingest.parse_idempotency_key(value) do
      {:ok, key} ->
        {:ok, key}

      {:error, _error} ->
        {:error,
         Relay.Error.new(:idempotency_key_invalid, "Idempotency-Key must be 8 to 255 characters")}
    end
  end

  defp missing,
    do:
      {:error,
       Relay.Error.new(:idempotency_key_missing, "this request needs an Idempotency-Key header")}

  # API-12
  # API-13
  # API-14
  # API-15
  # INV-2
  @doc "Runs `work` once for the key; see the module documentation."
  @spec run(Relay.Scope.t(), String.t(), String.t(), binary(), work()) ::
          {:ok, outcome()} | {:error, Relay.Error.t()}
  def run(%Relay.Scope{} = scope, endpoint, key, raw_body, work) when is_binary(key) do
    fingerprint = Relay.Ingest.idempotency_fingerprint(raw_body)

    with {:ok, field, data_key} <- seal_key(scope) do
      scope
      |> Relay.Ingest.in_scope(fn status ->
        claim(endpoint, key, fingerprint, fn -> work.(status) end, field, data_key)
      end)
      |> finish(scope)
    end
  end

  defp claim(endpoint, key, fingerprint, work, field, data_key) do
    case Relay.Ingest.idempotency_begin(endpoint, key, fingerprint) do
      {:created, nil} ->
        case work.() do
          {:ok, {status, headers, body} = response} when is_binary(body) ->
            store(endpoint, key, fingerprint, response, field, data_key)
            {:fresh, {status, headers, body}}

          {:error, %Relay.Error{} = error} ->
            Store.rollback(error)
        end

      {:replayed, stored} ->
        {:replayed, stored}

      {:in_progress, nil} ->
        Store.rollback(
          Relay.Error.new(:idempotency_key_in_progress, "a request with this key is in progress")
        )

      {:conflict, nil} ->
        Store.rollback(
          Relay.Error.new(:idempotency_key_reuse, "this key was used with a different body")
        )
    end
  end

  defp store(endpoint, key, fingerprint, {status, headers, body}, field, data_key) do
    if Relay.Ingest.idempotency_cacheable?(status) do
      {:ok, body_ct} = Relay.Tenancy.encrypt_field(field, body, data_key: data_key)

      stored = %{
        status: status,
        headers: Map.new(Enum.filter(headers, fn {name, _value} -> name in @stored_headers end)),
        body_ct: body_ct,
        body_key_id: field.key_id
      }

      case Relay.Ingest.idempotency_complete(endpoint, key, fingerprint, stored) do
        :stored -> :ok
        :not_cacheable -> :ok
        :not_claimed -> Store.rollback(Relay.Error.new(:accept_failed, "key not claimed"))
      end
    end
  end

  defp finish({:ok, {:fresh, response}}, _scope), do: {:ok, {:fresh, response}}

  defp finish({:ok, {:replayed, stored}}, scope) do
    with {:ok, body} <-
           Relay.Tenancy.decrypt_field(field(scope, stored.body_key_id), stored.body_ct) do
      response = {stored.status, Map.to_list(stored.headers), Relay.Redacted.expose(body)}
      {:ok, {:replayed, response}}
    end
  end

  defp finish({:error, %Relay.Error{} = error}, _scope), do: {:error, error}

  defp finish({:error, _reason}, _scope),
    do: {:error, Relay.Error.new(:service_unavailable, "the request could not be recorded")}

  defp seal_key(scope) do
    with {:ok, key_id} <- Relay.Tenancy.active_tenant_key(scope, :data),
         field = field(scope, key_id),
         {:ok, data_key} <- Relay.Tenancy.data_key(field) do
      {:ok, field, data_key}
    end
  end

  defp field(scope, key_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :delivery_record,
      table: "idempotency_keys",
      column: "response_body_ct",
      key_id: key_id
    }
  end
end
