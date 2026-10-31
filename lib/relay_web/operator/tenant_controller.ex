defmodule RelayWeb.Operator.TenantController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.Operators
  alias Relay.Operators.Admin
  alias Relay.Operators.Authz
  alias RelayWeb.Operator.Json

  # OP-51
  @spec send_modes(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def send_modes(conn, _params) do
    case Admin.send_modes(conn.assigns.operator_scope) do
      {:ok, %{levels: levels, default: default}} ->
        installation = %{
          "key" => "send_mode",
          "mode" => (default && default["mode"]) || "live",
          "updated_at" => (default && default["updated_at"]) || Relay.Clock.utc_now()
        }

        data =
          [Json.send_mode(installation, "installation")] ++
            Enum.map(levels, &Json.send_mode(&1, Json.level(&1["key"])))

        reply(conn, 200, %{
          "object" => "list",
          "data" => data,
          "has_more" => false,
          "next_cursor" => nil
        })

      {:error, error} ->
        problem(conn, error)
    end
  end

  # OP-51
  # TN-22
  @spec set_send_mode(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def set_send_mode(conn, _params) do
    body = conn.assigns.body
    scope = conn.assigns.operator_scope
    attrs = %{category: body["category"], channel: body["channel"], mode: body["mode"]}

    with :ok <- level(attrs),
         {:ok, relaxes} <- Admin.send_mode_relaxes(scope, attrs),
         {:ok, conn} <- if(relaxes, do: step_up(conn), else: {:ok, conn}) do
      idempotent(conn, fn -> write_send_mode(conn, scope, attrs) end)
    else
      {:error, error} -> problem(conn, error)
    end
  end

  defp write_send_mode(conn, scope, attrs) do
    with {:ok, row} <- Admin.set_send_mode(scope, attrs, actor(conn), step_up_ref(conn)) do
      key = Admin.send_mode_key(attrs)
      row = row || %{"key" => key, "mode" => "live", "updated_at" => Relay.Clock.utc_now()}
      row = Map.put(row, "updated_by", conn.assigns.operator_session.subject)
      {:ok, {200, Json.send_mode(row, Json.level(key))}}
    end
  end

  defp level(%{category: category, channel: nil}) when is_binary(category),
    do: {:error, field("/channel", "required", "category needs channel")}

  defp level(_attrs), do: :ok

  # API-51
  # TN-52
  @spec quotas(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def quotas(conn, _params) do
    case Admin.quota_policies(conn.assigns.operator_scope) do
      {:ok, policies} ->
        reply(conn, 200, %{
          "object" => "list",
          "data" => Enum.map(policies, &Json.quota_policy/1),
          "has_more" => false,
          "next_cursor" => nil
        })

      {:error, error} ->
        problem(conn, error)
    end
  end

  # API-51
  # TN-22
  # TN-52
  @spec set_quota(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def set_quota(conn, _params) do
    body = conn.assigns.body
    scope = conn.assigns.operator_scope

    with {:ok, plan} <- Admin.quota_change(scope, body),
         :ok <- quota_role(conn, plan),
         {:ok, conn} <- if(plan.relaxes?, do: step_up(conn), else: {:ok, conn}) do
      idempotent(conn, fn -> write_quota(conn, scope, plan, body["reason"]) end)
    else
      {:error, %Relay.Error{} = error} -> problem(conn, error)
    end
  end

  defp write_quota(conn, scope, plan, reason) do
    with {:ok, policy} <- Admin.set_quota_policy(scope, plan, reason, actor(conn)),
         do: {:ok, {200, Json.quota_policy(policy)}}
  end

  # TN-23
  defp quota_role(_conn, %{limit_changed?: false}), do: :ok

  defp quota_role(conn, _plan) do
    grants = conn.assigns.operator_session.grants

    if Authz.installation_operator?(grants, Operators.installation_tenant_id()) do
      :ok
    else
      {:error,
       Relay.Error.new(
         :auth_insufficient_role,
         "only the installation operator sets the limit",
         %{
           required_role: "installation_operator",
           granted_roles: granted_roles(conn)
         }
       )}
    end
  end

  defp granted_roles(conn) do
    conn.assigns.operator_session.grants
    |> Authz.granted(conn.assigns.operator_scope, Operators.installation_tenant_id())
    |> Enum.map(&Atom.to_string/1)
  end

  # API-52
  @spec api_version(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def api_version(conn, _params) do
    case Admin.api_version(conn.assigns.operator_scope) do
      {:ok, row} -> reply(conn, 200, Json.api_version(row))
      {:error, error} -> problem(conn, error)
    end
  end

  # API-52
  @spec set_api_version(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def set_api_version(conn, _params) do
    version = conn.assigns.body["version"]

    idempotent(conn, fn ->
      with {:ok, row} <- Admin.set_api_version(conn.assigns.operator_scope, version, actor(conn)) do
        {:ok, {200, Json.api_version(row)}}
      end
    end)
  end
end
