defmodule Relay.Iys.Client do
  @moduledoc """
  The İYS API client (PC-34, CH-3, T-40), written against the transcription of the official document in `conformance/iys/openapi.yaml`. It is a thin Req client: no retry, no redirect, one request per call, and `Relay.NetworkGuard` before each, so a request never runs inside a database transaction.

  A connection is a map with `:base_url`, `:iys_code`, `:integrator_code` (or `nil`), `:username`, `:password` (redacted), `:cache_key` and optionally `:cache` (the token cache, `Relay.Iys.TokenCache` by default) and `:rate` (a function asked before each request with `:api`, `:status` or `:token`, answering `:allow` or `{:deny, wait_ms}`).

  The access token is taken from the token cache for its whole lifetime; only without a live token is the token endpoint asked, with the refresh token while that lives and with the password otherwise. A token request İYS limits (`429`) blocks the key for an hour, and nothing asks again before it ends. A request İYS answers `401` to is sent once more with a new token.

  An answer is `{:ok, value}` or `{:error, failure}`; a failure carries `:class` (`:retry` for a transport error, a `5xx` or a busy service, `:rate_limited`, `:unauthorised`, `:forbidden`, or `:rejected` for a request İYS refuses for what it says), the HTTP `:status`, the first İYS error `:code`, `:retry_after_s` and the `X-Trace-Id` of the answer as `:trace`. No failure carries a body, an address or a secret.

  The installation may add Req options under `config :relay, Relay.Iys, http: [...]`, which the tests use to reach the İYS fake.
  """

  alias Relay.Iys.Calendar
  alias Relay.Iys.Consent
  alias Relay.Iys.TokenCache
  alias Relay.Redacted

  @receive_ms 15_000
  @connect_ms 5_000
  @hour_s 3_600
  @page 100

  @type conn :: %{
          required(:base_url) => String.t(),
          required(:iys_code) => pos_integer(),
          required(:integrator_code) => pos_integer() | nil,
          required(:username) => String.t(),
          required(:password) => Redacted.t(),
          required(:cache_key) => term(),
          optional(:cache) => GenServer.server(),
          optional(:rate) => (atom() -> :allow | {:deny, non_neg_integer()})
        }
  @type failure :: %{
          class: :retry | :rate_limited | :unauthorised | :forbidden | :rejected,
          status: non_neg_integer() | nil,
          code: String.t() | nil,
          retry_after_s: non_neg_integer() | nil,
          trace: String.t() | nil
        }
  @type result(value) :: {:ok, value} | {:error, failure()}
  @type added :: %{
          transaction_id: String.t(),
          registered_at: DateTime.t() | nil,
          trace: String.t() | nil
        }

  # PC-34
  @doc "The access token of a connection: the cached one while it lives, otherwise a new one from the token endpoint."
  @spec token(conn()) :: result(Redacted.t())
  def token(conn) do
    case TokenCache.lookup(cache(conn), conn.cache_key) do
      {:ok, token} -> {:ok, token}
      {:blocked, seconds} -> {:error, failure(:rate_limited, 429, "H084", seconds, nil)}
      {:refresh, refresh} -> granted(conn, refresh_grant(refresh), true)
      :miss -> granted(conn, password_grant(conn), false)
    end
  end

  defp password_grant(conn) do
    %{
      "grant_type" => "password",
      "username" => conn.username,
      "password" => Redacted.expose(conn.password)
    }
  end

  defp refresh_grant(refresh),
    do: %{"grant_type" => "refresh_token", "refresh_token" => Redacted.expose(refresh)}

  defp granted(conn, grant, refresh?) do
    with :ok <- allowed(conn, :token) do
      request = [method: :post, url: "/oauth2/token", json: grant]

      case send_request(conn, request) do
        {:ok, %Req.Response{} = response} -> issued(conn, response, refresh?)
        {:error, _transport} -> {:error, failure(:retry, nil, nil, nil, nil)}
      end
    end
  end

  defp issued(conn, %Req.Response{status: 200, body: %{"access_token" => access} = body}, _)
       when is_binary(access),
       do: keep(conn, body)

  defp issued(conn, %Req.Response{status: 429} = response, _refresh?) do
    TokenCache.block(cache(conn), conn.cache_key, @hour_s)
    {:error, failure(:rate_limited, 429, code(response), @hour_s, trace(response))}
  end

  defp issued(conn, %Req.Response{status: status}, true) when status in [400, 401] do
    TokenCache.drop(cache(conn), conn.cache_key)
    granted(conn, password_grant(conn), false)
  end

  defp issued(_conn, %Req.Response{status: status} = response, false) when status in [400, 401],
    do: {:error, failure(:unauthorised, status, code(response), nil, trace(response))}

  defp issued(_conn, %Req.Response{} = response, _refresh?), do: {:error, classified(response)}

  defp keep(conn, %{"access_token" => access} = body) do
    token = Redacted.wrap(access)
    lifetime = integer(body["expires_in"]) || 0
    refresh = wrapped(body["refresh_token"])
    refresh_lifetime = integer(body["refresh_expires_in"])

    :ok = TokenCache.put(cache(conn), conn.cache_key, token, lifetime, refresh, refresh_lifetime)
    {:ok, token}
  end

  defp wrapped(value) when is_binary(value), do: Redacted.wrap(value)
  defp wrapped(_other), do: nil

  # PC-30
  @doc "Records one consent with the idempotent v2 operation; answers the İYS transaction identifier, the instant İYS recorded it and the trace identifier."
  @spec add_consent(conn(), pos_integer(), Consent.t()) :: result(added())
  def add_consent(conn, brand_code, consent) do
    path = "/v2" <> brand_path(conn, brand_code) <> "/consents"
    request = [method: :post, url: path, json: Consent.body(consent)]

    with {:ok, response} <- call(conn, :api, request) do
      case response do
        %Req.Response{status: 200, body: %{"transactionId" => id} = body} when is_binary(id) ->
          registered = Calendar.parse_time(body["creationDate"])
          {:ok, %{transaction_id: id, registered_at: registered, trace: trace(response)}}

        other ->
          {:error, classified(other)}
      end
    end
  end

  # PC-34
  @doc "Hands a list of consents to the asynchronous v2 operation; answers the request identifier to ask `batch_status/3` about."
  @spec add_batch(conn(), pos_integer(), [Consent.t()]) ::
          result(%{request_id: String.t(), trace: String.t() | nil})
  def add_batch(conn, brand_code, consents) when is_list(consents) do
    path = "/v2" <> brand_path(conn, brand_code) <> "/consents/request"
    body = Enum.map(consents, &Consent.body/1)

    with {:ok, response} <- call(conn, :api, method: :post, url: path, json: body) do
      case response do
        %Req.Response{status: 202, body: %{"requestId" => id}} when is_binary(id) ->
          {:ok, %{request_id: id, trace: trace(response)}}

        other ->
          {:error, classified(other)}
      end
    end
  end

  # PC-34
  @doc "Reads the entries of an asynchronous request: for each consent its `index`, its `status` (`success`, `failure` or `enqueue`), its transaction identifier and its error code. An empty list means İYS has not processed the request yet."
  @spec batch_status(conn(), pos_integer(), String.t()) :: result([map()])
  def batch_status(conn, brand_code, request_id) when is_binary(request_id) do
    path = "/v2#{brand_path(conn, brand_code)}/consents/request/#{URI.encode(request_id)}"

    with {:ok, response} <- call(conn, :api, method: :get, url: path) do
      case response do
        %Req.Response{status: 200, body: items} when is_list(items) ->
          {:ok, Enum.map(items, &batch_item/1)}

        other ->
          {:error, classified(other)}
      end
    end
  end

  defp batch_item(%{} = item) do
    %{
      index: item["index"],
      status: item["status"],
      transaction_id: item["transactionId"],
      registered_at: Calendar.parse_time(item["creationDate"]),
      error_code: get_in(item, ["error", "code"])
    }
  end

  defp batch_item(_other),
    do: %{index: nil, status: nil, transaction_id: nil, registered_at: nil, error_code: nil}

  # PC-30
  @doc "Reads the consent İYS holds for a recipient, type and recipient type: its `status`, transaction identifier, source and dates, or `nil` when İYS holds none. İYS limits this operation by the hour."
  @spec consent_status(conn(), pos_integer(), map()) :: result(map() | nil)
  def consent_status(conn, brand_code, %{recipient: recipient, type: type} = query) do
    path = brand_path(conn, brand_code) <> "/consents/status"

    body = %{
      "recipient" => recipient,
      "type" => type,
      "recipientType" => Map.get(query, :recipient_type, "BIREYSEL")
    }

    with {:ok, response} <- call(conn, :status, method: :post, url: path, json: body) do
      case response do
        %Req.Response{status: 200, body: %{"status" => status} = row} when is_binary(status) ->
          {:ok, held(row)}

        %Req.Response{status: status} when status in [200, 204, 404] ->
          {:ok, nil}

        other ->
          {:error, classified(other)}
      end
    end
  end

  defp held(found) do
    %{
      status: found["status"],
      transaction_id: found["transactionId"],
      source: found["source"],
      consent_at: Calendar.parse_time(found["consentDate"]),
      registered_at: Calendar.parse_time(found["creationDate"])
    }
  end

  # PC-32
  @doc "Reads consent movements after the cursor `:after` (`nil` for the start of the seven-day window), at most `:limit`, of `:source` `HS` or `IYS`; answers the movements as İYS wrote them and the next cursor."
  @spec changes(conn(), pos_integer(), keyword()) ::
          result(%{after: String.t() | nil, list: [map()]})
  def changes(conn, brand_code, opts \\ []) do
    given = [after: opts[:after], limit: opts[:limit], source: opts[:source]]
    params = Enum.reject(given, fn {_name, value} -> is_nil(value) end)

    path = brand_path(conn, brand_code) <> "/consents/changes"

    with {:ok, response} <- call(conn, :api, method: :get, url: path, params: params) do
      case response do
        %Req.Response{status: 200, body: %{"list" => list} = body} when is_list(list) ->
          {:ok, %{after: body["after"], list: list}}

        %Req.Response{status: 204} ->
          {:ok, %{after: opts[:after], list: []}}

        other ->
          {:error, classified(other)}
      end
    end
  end

  # PC-29
  @doc "Lists the brands of the service provider: `brand_code`, `name` and `master`."
  @spec brands(conn()) :: result([map()])
  def brands(conn) do
    path = "/sps/#{conn.iys_code}/brands"

    with {:ok, response} <- call(conn, :api, method: :get, url: path) do
      case response do
        %Req.Response{status: 200, body: body} when is_list(body) or is_map(body) ->
          {:ok, body |> List.wrap() |> Enum.flat_map(&brand/1)}

        other ->
          {:error, classified(other)}
      end
    end
  end

  defp brand(%{"brandCode" => code} = brand) do
    case integer(code) do
      nil -> []
      code -> [%{brand_code: code, name: brand["name"], master: brand["master"] == true}]
    end
  end

  defp brand(_other), do: []

  # PC-29
  # E-22
  @doc "Lists what the integrator is authorised for at the service provider, page by page: for each brand its `brand_code` and the access by type (`message_access`, `call_access`, `email_access`, each `write`, `read` or `none`)."
  @spec authorisations(conn()) :: result([map()])
  def authorisations(%{integrator_code: code} = conn) when is_integer(code),
    do: authorisation_pages(conn, 0, [])

  defp authorisation_pages(conn, offset, acc) do
    path = "/integrator/#{conn.integrator_code}/sps/#{conn.iys_code}"
    params = [offset: offset, limit: @page]

    with {:ok, response} <- call(conn, :api, method: :get, url: path, params: params) do
      case response do
        %Req.Response{status: 200, body: %{"list" => list} = body} when is_list(list) ->
          total = integer(get_in(body, ["pagination", "totalCount"])) || 0
          next_page(conn, offset + length(list), total, list, acc)

        other ->
          {:error, classified(other)}
      end
    end
  end

  defp next_page(_conn, _read, _total, [], acc), do: {:ok, acc}

  defp next_page(conn, read, total, list, acc) do
    acc = acc ++ Enum.flat_map(list, &authorisation/1)
    if read < total, do: authorisation_pages(conn, read, acc), else: {:ok, acc}
  end

  defp authorisation(%{"brandCode" => code} = entry) do
    case integer(code) do
      nil ->
        []

      code ->
        [
          %{
            brand_code: code,
            message_access: access(entry["MESAJ"]),
            call_access: access(entry["ARAMA"]),
            email_access: access(entry["EPOSTA"])
          }
        ]
    end
  end

  defp authorisation(_other), do: []

  defp access("write"), do: "write"
  defp access("read"), do: "read"
  defp access(_other), do: "none"

  # PC-34
  @doc "Reads the subscription of the service provider: `status`, `consent_limit`, `used_consent_limit` and `consent_limit_exceed`."
  @spec subscription(conn()) :: result(map())
  def subscription(conn) do
    path = "/sps/#{conn.iys_code}/subscription"

    with {:ok, response} <- call(conn, :api, method: :get, url: path) do
      case response do
        %Req.Response{status: 200, body: %{} = body} ->
          {:ok,
           %{
             status: body["status"],
             consent_limit: integer(body["consentLimit"]),
             used_consent_limit: integer(body["usedConsentLimit"]),
             consent_limit_exceed: body["consentLimitExceed"] == true
           }}

        other ->
          {:error, classified(other)}
      end
    end
  end

  defp brand_path(conn, brand_code), do: "/sps/#{conn.iys_code}/brands/#{brand_code}"

  defp call(conn, kind, opts) do
    with :ok <- allowed(conn, kind),
         {:ok, token} <- token(conn) do
      case authorised(conn, token, opts) do
        {:ok, %Req.Response{status: 401}} -> again(conn, opts)
        {:ok, %Req.Response{} = response} -> {:ok, response}
        {:error, _transport} -> {:error, failure(:retry, nil, nil, nil, nil)}
      end
    end
  end

  defp again(conn, opts) do
    TokenCache.drop(cache(conn), conn.cache_key)

    with {:ok, token} <- token(conn) do
      case authorised(conn, token, opts) do
        {:ok, %Req.Response{} = response} -> {:ok, response}
        {:error, _transport} -> {:error, failure(:retry, nil, nil, nil, nil)}
      end
    end
  end

  defp authorised(conn, token, opts),
    do: send_request(conn, Keyword.put(opts, :auth, {:bearer, Redacted.expose(token)}))

  defp allowed(%{rate: rate}, kind) when is_function(rate, 1) do
    case rate.(kind) do
      {:deny, wait_ms} ->
        {:error, failure(:rate_limited, nil, nil, div(wait_ms, 1000) + 1, nil)}

      _allow ->
        :ok
    end
  end

  defp allowed(_conn, _kind), do: :ok

  # T-43
  defp send_request(conn, opts) do
    extra = :relay |> Application.get_env(Relay.Iys, []) |> Keyword.get(:http, [])

    opts =
      [
        base_url: conn.base_url,
        retry: false,
        redirect: false,
        receive_timeout: @receive_ms,
        connect_options: [timeout: @connect_ms]
      ]
      |> Keyword.merge(opts)
      |> Keyword.merge(extra)

    :ok = Relay.NetworkGuard.check!(:http)
    Req.request(opts)
  end

  defp classified(%Req.Response{status: status} = response) do
    code = code(response)
    failure(class(status, code), status, code, retry_after(status, code), trace(response))
  end

  defp class(status, _code) when status >= 500, do: :retry
  defp class(429, _code), do: :rate_limited
  defp class(401, _code), do: :unauthorised
  defp class(403, _code), do: :forbidden
  defp class(400, "H123"), do: :retry
  defp class(_status, _code), do: :rejected

  defp retry_after(429, code) when code in ["H084", "H086", "H089"], do: @hour_s
  defp retry_after(429, _code), do: 1
  defp retry_after(_status, _code), do: nil

  defp code(%Req.Response{body: %{"errors" => [%{"code" => code} | _rest]}}), do: bounded(code)

  defp code(%Req.Response{body: %{"errors" => %{"code" => code}}}), do: bounded(code)
  defp code(%Req.Response{body: %{"error" => code}}), do: bounded(code)
  defp code(_response), do: nil

  defp bounded(code) when is_binary(code), do: String.slice(code, 0, 64)
  defp bounded(code) when is_integer(code), do: Integer.to_string(code)
  defp bounded(_other), do: nil

  defp trace(%Req.Response{} = response) do
    case Req.Response.get_header(response, "x-trace-id") do
      [value | _rest] -> String.slice(value, 0, 64)
      [] -> nil
    end
  end

  defp failure(class, status, code, retry_after_s, trace),
    do: %{class: class, status: status, code: code, retry_after_s: retry_after_s, trace: trace}

  defp cache(conn), do: Map.get(conn, :cache, TokenCache)

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp integer(_other), do: nil
end
