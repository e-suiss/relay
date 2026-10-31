defmodule RelayWeb.Operator.SupportController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.Operators.Admin
  alias RelayWeb.Api.Response
  alias RelayWeb.Operator.Json

  # TN-23
  @spec delegations(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delegations(conn, _params) do
    own = if conn.assigns.delegation_id, do: conn.assigns.operator_session.operator_id

    with {:ok, limit, after_id} <- page_params(conn),
         {:ok, rows} <- Admin.delegations(conn.assigns.operator_scope, own, after_id, limit + 1) do
      page(conn, rows, limit, &Json.delegation/1)
    else
      {:error, error} -> problem(conn, error)
    end
  end

  # TN-23
  # TN-21
  @spec grant(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def grant(conn, _params) do
    body = conn.assigns.body

    idempotent(conn, fn ->
      with {:ok, operator_id} <- body_id(body["operator_id"], "opr", "/operator_id"),
           {:ok, duration} <- delegation_duration(body["duration"]),
           attrs = %{operator_id: operator_id, reason: body["reason"], duration_s: duration},
           {:ok, row} <-
             Admin.grant_delegation(
               conn.assigns.operator_scope,
               attrs,
               actor(conn),
               step_up_ref(conn)
             ) do
        {:ok, {201, Json.delegation(row)}}
      end
    end)
  end

  defp delegation_duration(nil), do: {:ok, nil}

  defp delegation_duration(text) do
    case duration(text) do
      {:ok, seconds} -> {:ok, seconds}
      :error -> {:error, field("/duration", "invalid_format", "an ISO 8601 duration")}
    end
  end

  # TN-23
  @spec revoke(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def revoke(conn, %{"delegation_id" => id}) do
    idempotent(conn, fn ->
      with {:ok, id} <- path_id(id, "dlg", :support_delegation_not_found),
           {:ok, row} <-
             Admin.revoke_delegation(
               conn.assigns.operator_scope,
               id,
               conn.assigns.body["reason"],
               actor(conn)
             ) do
        {:ok, {200, Json.delegation(row)}}
      end
    end)
  end

  # X-5
  # TN-21
  # TN-47
  @spec reveal(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reveal(conn, %{"subscriber_id" => id}) do
    body = conn.assigns.body

    with {:ok, subscriber_id} <- path_id(id, "sub", :subscriber_not_found),
         {:ok, %{fields: fields, audit_ids: ids}} <-
           Admin.reveal(
             conn.assigns.operator_scope,
             subscriber_id,
             body["fields"],
             body["reason"],
             actor(conn)
           ) do
      Response.json(conn, 200, %{
        "object" => "pii_reveal",
        "subscriber_id" => id,
        "fields" => fields,
        "audit_ids" => Enum.map(ids, &Json.id("aud", &1))
      })
    else
      {:error, error} -> problem(conn, error)
    end
  end

  # API-44
  @spec api_clients(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def api_clients(conn, _params) do
    scope = conn.assigns.operator_scope

    with {:ok, limit, after_id} <- page_params(conn),
         {:ok, %{clients: clients}} <- Relay.Access.api_clients(scope) do
      rows =
        clients
        |> Enum.sort_by(& &1.id)
        |> Enum.drop_while(&(after_id != nil and &1.id <= after_id))
        |> Enum.map(&Map.put(&1, "id", &1.id))
        |> Enum.take(limit + 1)

      page(conn, rows, limit, &Json.api_client(&1, scope))
    else
      {:error, %Relay.Error{} = error} -> problem(conn, error)
      {:error, _reason} -> problem(conn, Relay.Error.new(:service_unavailable, "unavailable"))
    end
  end

  # API-44
  @spec api_client(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def api_client(conn, %{"api_client_id" => id}) do
    scope = conn.assigns.operator_scope

    with {:ok, id} <- path_id(id, "cli", :api_client_not_found),
         {:ok, %{clients: clients}} <- Relay.Access.api_clients(scope),
         %{} = client <- Enum.find(clients, &(&1.id == id)) do
      reply(conn, 200, Json.api_client(client, scope))
    else
      nil -> problem(conn, Relay.Error.new(:api_client_not_found, "no such API client"))
      {:error, %Relay.Error{} = error} -> problem(conn, error)
      {:error, _reason} -> problem(conn, Relay.Error.new(:service_unavailable, "unavailable"))
    end
  end

  # TN-50
  @spec audit_log(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def audit_log(conn, params) do
    with {:ok, limit, after_id} <- page_params(conn),
         {:ok, from} <- query_time(params, "from"),
         {:ok, to} <- query_time(params, "to"),
         query = %{
           from: from,
           to: to,
           action: params["action"],
           after_id: after_id,
           limit: limit + 1
         },
         {:ok, rows} <- Admin.audit_log(conn.assigns.operator_scope, query, actor(conn)) do
      page(conn, rows, limit, &Json.audit/1)
    else
      {:error, error} -> problem(conn, error)
    end
  end

  defp query_time(params, name) do
    case timestamp(params[name]) do
      {:ok, at} -> {:ok, at}
      :error -> {:error, field("/query/" <> name, "required", "an RFC 3339 time")}
    end
  end
end
