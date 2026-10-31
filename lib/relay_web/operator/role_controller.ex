defmodule RelayWeb.Operator.RoleController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.Operators.Admin
  alias RelayWeb.Operator.Json

  @roles %{"tenant_admin" => :tenant_admin, "tenant_operator" => :tenant_operator}

  # TN-19
  # TN-23
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    reply(conn, 200, Relay.Api.Pagination.envelope(Json.roles(), false, nil))
  end

  @spec assignments(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def assignments(conn, _params) do
    with {:ok, limit, after_id} <- page_params(conn),
         {:ok, rows} <- Admin.role_assignments(conn.assigns.operator_scope, after_id, limit + 1) do
      page(conn, rows, limit, &Json.role_assignment/1)
    else
      {:error, error} -> problem(conn, error)
    end
  end

  # TN-21
  # TN-23
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    body = conn.assigns.body
    scope = conn.assigns.operator_scope
    environments = body["environments"] || [Relay.Environment.dump(scope.environment)]

    idempotent(conn, fn ->
      with {:ok, operator_id} <- body_id(body["operator_id"], "opr", "/operator_id") do
        attrs = %{
          operator_id: operator_id,
          role: Map.fetch!(@roles, body["role"]),
          reason: body["reason"]
        }

        assign_each(conn, scope, environments, attrs)
      end
    end)
  end

  defp assign_each(conn, scope, environments, attrs) do
    actor = actor(conn)

    results =
      for environment <-
            Enum.sort_by(environments, &(&1 != Relay.Environment.dump(scope.environment))) do
        target = Relay.Scope.new!(scope.tenant_id, environment)
        Admin.assign_role(target, attrs, actor, step_up_ref(conn))
      end

    case results do
      [{:ok, row} | rest] ->
        case Enum.find(rest, &match?({:error, _}, &1)) do
          nil -> {:ok, {201, Json.role_assignment(row)}}
          {:error, error} -> {:error, error}
        end

      [{:error, error} | _rest] ->
        {:error, error}
    end
  end

  # TN-21
  @spec revoke(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def revoke(conn, %{"role_assignment_id" => id}) do
    scope = conn.assigns.operator_scope

    idempotent(conn, fn ->
      with {:ok, id} <- path_id(id, "rla", :role_assignment_not_found),
           {:ok, row} <-
             Admin.revoke_role(
               scope,
               id,
               conn.assigns.body["reason"],
               actor(conn),
               step_up_ref(conn)
             ) do
        {:ok, {200, Json.role_assignment(row)}}
      end
    end)
  end
end
