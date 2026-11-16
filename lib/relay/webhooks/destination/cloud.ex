defmodule Relay.Webhooks.Destination.Cloud do
  @moduledoc """
  What the cloud destinations share (WH-17, WH-18): the queues, topics, buses and object stores that are written with one signed HTTPS call. Every call goes through `Relay.Webhooks.Egress`, so the egress rules hold for the API host, for a custom endpoint and for a token endpoint alike (WH-43).

  `settle/1` reads the answer of a write. A 2xx answer is the acknowledgement of the durable write and becomes a receipt of kind `:write`. Any other answer is a failure of the attempt, not a webhook response: 401 and 403 mean the credentials are not accepted now (`:credentials`), 408, 425, 429 and 5xx that the service is not available now (`:unavailable`), and every other status that the service refused the message for good (`:rejected`). The reason carries the status and nothing of the response.

  A credential is a wrapped value from the moment it arrives to the header it is written into; it is in no receipt and in no failure (WH-19).
  """

  alias Relay.Redacted
  alias Relay.Webhooks.Destination
  alias Relay.Webhooks.Egress

  @egress_options [
    :connect_timeout_ms,
    :total_timeout_ms,
    :max_response_bytes,
    :dns_timeout_ms,
    :resolver,
    :transport,
    :ca_certificates,
    :proxy
  ]
  @kept_classes [:invalid, :blocked]
  @modes %{"structured" => :structured, "binary" => :binary}

  @type mode :: :structured | :binary
  @type answer :: {:ok, Egress.response()} | {:error, Egress.error()}
  @type result :: {:ok, Destination.receipt()} | {:error, Destination.failure()}
  @type fetched :: {:ok, Redacted.t(), pos_integer() | nil} | {:error, Destination.failure()}

  # WH-43
  @doc "Sends one request through the egress boundary with the policy and the limits of `opts`."
  @spec request(keyword(), Egress.request()) :: answer()
  def request(opts, request) when is_list(opts) do
    policy = Keyword.fetch!(opts, :policy)
    Egress.request(policy, request, Keyword.take(opts, @egress_options))
  end

  # WH-18
  @doc "Reads the answer of a write: a 2xx answer is the acknowledgement, anything else a failure."
  @spec settle(answer()) :: result()
  def settle({:ok, %{status: status} = response}) when status >= 200 and status <= 299,
    do: {:ok, receipt(response)}

  def settle({:ok, %{status: status} = response}),
    do: {:error, failure(class(status), "http_" <> Integer.to_string(status), response)}

  def settle({:error, error}), do: {:error, error}

  defp class(status) when status in [401, 403], do: :credentials
  defp class(status) when status in [408, 425, 429] or status >= 500, do: :unavailable
  defp class(_status), do: :rejected

  # WH-18
  @doc "The receipt of an acknowledged write."
  @spec receipt(Egress.response()) :: Destination.receipt()
  def receipt(%{status: status, duration_ms: duration_ms, address: address}),
    do: %{kind: :write, status: status, duration_ms: duration_ms, address: address}

  @doc "A failure of `class` at the place and with the duration of an answer or an error."
  @spec failure(Destination.failure_class(), String.t(), map()) :: Destination.failure()
  def failure(class, reason, %{duration_ms: duration_ms, address: address}),
    do: %{class: class, reason: reason, duration_ms: duration_ms, address: address}

  @doc "The failure of a destination whose configuration cannot be used; no attempt was made."
  @spec invalid(String.t()) :: {:error, Destination.failure()}
  def invalid(reason) when is_binary(reason), do: unattempted(:invalid, reason)

  @doc "A failure that was reached before any connection was opened."
  @spec unattempted(Destination.failure_class(), String.t()) :: {:error, Destination.failure()}
  def unattempted(class, reason) when is_atom(class) and is_binary(reason),
    do: {:error, %{class: class, reason: reason, duration_ms: 0, address: nil}}

  # WH-17
  # WH-43
  @doc """
  The failure of a credential request, such as a token endpoint or a role assumption, from its answer or its error. A request that was refused by the egress rules keeps its class; everything else means the credentials are not available now, with `prefix` in front of the reason.
  """
  @spec credential_failure(String.t(), answer()) :: {:error, Destination.failure()}
  def credential_failure(_prefix, {:error, %{class: class} = error}) when class in @kept_classes,
    do: {:error, error}

  def credential_failure(prefix, {:error, error}),
    do: {:error, failure(:credentials, prefix <> "_" <> error.reason, error)}

  def credential_failure(prefix, {:ok, %{status: status} = response}),
    do: {:error, failure(:credentials, prefix <> "_http_" <> Integer.to_string(status), response)}

  # WH-19
  @doc "The value the endpoint's cache holds for this destination: `fetch` runs only when the cache has none that is still valid. The cache is the `:token_cache` option, as for an HTTPS endpoint with OAuth2."
  @spec cached(keyword(), (-> fetched())) :: {:ok, Redacted.t()} | {:error, Destination.failure()}
  def cached(opts, fetch) when is_list(opts) and is_function(fetch, 0) do
    case Keyword.fetch(opts, :token_cache) do
      {:ok, cache} when is_function(cache, 1) -> cache.(fetch)
      _missing -> unattempted(:credentials, "token_cache_missing")
    end
  end

  # WH-8 (3)
  @doc "The CloudEvents mode of a destination: `cloudevents_mode` of its configuration, or `default`."
  @spec mode(map(), mode()) :: {:ok, mode()} | {:error, Destination.failure()}
  def mode(config, default) when is_map(config) and default in [:structured, :binary] do
    case Map.get(config, :cloudevents_mode) do
      nil -> {:ok, default}
      mode when is_map_key(@modes, mode) -> {:ok, Map.fetch!(@modes, mode)}
      _other -> invalid("cloudevents_mode_invalid")
    end
  end

  # WH-8 (3)
  @doc "The content type of `data` in binary mode: the `datacontenttype` attribute of the event."
  @spec data_content_type(Destination.prepared()) :: String.t()
  def data_content_type(%{attributes: attributes}) do
    case List.keyfind(attributes, "datacontenttype", 0) do
      {"datacontenttype", type} -> type
      nil -> "application/json"
    end
  end

  @doc "The time of this attempt: the `:now` option, or the clock."
  @spec now(keyword()) :: DateTime.t()
  def now(opts) when is_list(opts), do: Keyword.get_lazy(opts, :now, &Relay.Clock.utc_now/0)
end
