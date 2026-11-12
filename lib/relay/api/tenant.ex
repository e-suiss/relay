defmodule Relay.Api.Tenant do
  @moduledoc """
  What the API edge reads about a tenant before a request's work, in one scoped read: its status, its pinned API version, its API rate limit settings, whether it requires certificate-bound tokens (`api.mtls_required`, RFC 8705) and the browser origins allowed to open a realtime connection (`realtime.allowed_origins`, IN-54); and the automatic API version pin written after a tenant's first successful request, in a short transaction of its own.
  """

  alias Relay.Api.Store

  @mtls "api.mtls_required"
  @origins "realtime.allowed_origins"

  @type edge :: %{
          status: :active | :suspended | :closed,
          api_version: String.t() | nil,
          rate_settings: %{optional(String.t()) => map()},
          mtls_required: boolean(),
          realtime_origins: [String.t()]
        }

  # API-41
  # API-47
  # API-50
  # API-52
  @doc "Reads the tenant facts of a request; an unknown tenant is an invalid token, a failed read is `service_unavailable`."
  @spec edge(Relay.Scope.t()) :: {:ok, edge()} | {:error, Relay.Error.t()}
  def edge(%Relay.Scope{} = scope) do
    case Store.in_scope(scope, &read/1) do
      {:ok, edge} ->
        {:ok, edge}

      {:error, %Relay.Error{code: :not_found}} ->
        {:error, Relay.Error.new(:auth_invalid_token, "the token names no known tenant")}

      {:error, _reason} ->
        {:error, Relay.Error.new(:service_unavailable, "tenant facts could not be read")}
    end
  end

  defp read(status) do
    settings = Store.edge_settings()

    %{
      status: status,
      api_version: Store.api_version(),
      rate_settings: Map.filter(settings, fn {key, value} -> key != @mtls and is_map(value) end),
      mtls_required: Map.get(settings, @mtls) == true,
      realtime_origins: origins(Map.get(settings, @origins))
    }
  end

  defp origins(origins) when is_list(origins), do: origins
  defp origins(_none), do: []

  # API-52
  @doc "Pins the tenant to `version` unless a version is pinned already; audited as `api_version.pinned`."
  @spec pin(Relay.Scope.t(), String.t(), Relay.Actor.t()) ::
          {:ok, :pinned | :already_pinned | :changed | :unchanged | :unsupported}
          | {:error, term()}
  def pin(%Relay.Scope{} = scope, version, actor) do
    digest =
      :crypto.hash(
        :sha256,
        Relay.Canonical.encode!(["api_version.pinned", {:bytes, scope.tenant_id}, version])
      )

    Store.in_scope(scope, fn _status -> Store.api_version_pin(version, true, digest, actor) end)
  end
end
