defmodule Relay.TenantLifecycle.ExportStore do
  @moduledoc """
  Object store of the full export of a closing tenant: the installation's store in its own region. The store is configured as `config :relay, Relay.TenantLifecycle, export_store: {module, options}`; without one a closure is recorded but its export waits and is retried. See `Relay.TenantLifecycle.ExportStore.S3`.
  """

  @callback put(String.t(), iodata(), String.t(), keyword()) :: :ok | {:error, Relay.Error.t()}
  @callback url(String.t(), pos_integer(), keyword()) ::
              {:ok, String.t()} | {:error, Relay.Error.t()}

  # OP-86
  @doc "Writes the object `key` with `body` and its content type to the configured store."
  @spec put(String.t(), iodata(), String.t()) :: :ok | {:error, Relay.Error.t()}
  def put(key, body, content_type) do
    with {:ok, {module, opts}} <- configured(), do: module.put(key, body, content_type, opts)
  end

  # OP-86
  @doc "A signed download link of the object `key` that expires after `ttl_s` seconds."
  @spec url(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def url(key, ttl_s) do
    with {:ok, {module, opts}} <- configured(), do: module.url(key, ttl_s, opts)
  end

  defp configured do
    case :relay |> Application.get_env(Relay.TenantLifecycle, []) |> Keyword.get(:export_store) do
      {module, opts} when is_atom(module) and is_list(opts) ->
        {:ok, {module, opts}}

      _ ->
        {:error, Relay.Error.new(:export_store_unconfigured, "no export store is configured")}
    end
  end
end
