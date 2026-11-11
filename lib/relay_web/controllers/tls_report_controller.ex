defmodule RelayWeb.TlsReportController do
  @moduledoc false

  use RelayWeb, :controller

  @max_body 1_048_576
  @window_ms 3_600_000
  @per_window 120
  @types %{"application/tlsrpt+json" => :json, "application/tlsrpt+gzip" => :gzip}

  # CH-46
  # CH-87
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"tenant" => tenant, "environment" => environment}) do
    with {:ok, scope} <- scope(tenant, environment),
         {:ok, encoding} <- encoding(conn),
         {:ok, body, conn} <- body(conn),
         :ok <- admitted(scope),
         {:ok, report} <- parse(encoding, body) do
      store(conn, scope, report, :crypto.hash(:sha256, body))
    else
      {:error, status} -> send_resp(conn, status, "")
      {:error, status, conn} -> send_resp(conn, status, "")
    end
  end

  defp scope(tenant, environment) do
    with {:ok, tenant_id} <- Relay.ExternalId.decode(tenant, ["ten"]),
         {:ok, environment} <- Relay.Environment.cast(environment) do
      {:ok, Relay.Scope.new!(tenant_id, environment)}
    else
      _invalid -> {:error, 404}
    end
  end

  defp encoding(conn) do
    with [value | _rest] <- get_req_header(conn, "content-type"),
         {:ok, type, subtype, _params} <- Plug.Conn.Utils.content_type(value),
         {:ok, encoding} <- Map.fetch(@types, type <> "/" <> subtype) do
      {:ok, encoding}
    else
      _other -> {:error, 415}
    end
  end

  defp body(conn) do
    case read_body(conn, length: @max_body) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, 413, conn}
      {:error, _reason} -> {:error, 400}
    end
  end

  # CH-87
  defp admitted(scope) do
    member = Relay.Id.to_string(Relay.Id.generate())
    path = ["tlsrpt"]

    with {:ok, %{count: count}} when count < @per_window <-
           Relay.Platform.sliding_set_count(scope, path, @window_ms, member, @per_window),
         {:ok, _added} <- Relay.Platform.sliding_set_add(scope, path, @window_ms, member) do
      :ok
    else
      {:ok, _limited} -> {:error, 429}
      {:error, _reason} -> {:error, 503}
    end
  end

  defp parse(encoding, body) do
    case Relay.Channels.parse_email_report(:tls_rpt, encoding, body) do
      {:ok, report} -> {:ok, report}
      {:error, :report_too_large} -> {:error, 413}
      {:error, :invalid_report} -> {:error, 400}
    end
  end

  defp store(conn, scope, report, digest) do
    case Relay.Channels.store_email_report(scope, report, digest) do
      {:ok, {_result, _id}} -> send_resp(conn, 202, "")
      {:error, :tenant_not_found} -> send_resp(conn, 404, "")
      {:error, _reason} -> send_resp(conn, 503, "")
    end
  end
end
