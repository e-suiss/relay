defmodule RelayWeb.Operator.TenantLifecycleController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.TenantLifecycle

  # OP-85
  @spec key_custody(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def key_custody(conn, %{"tenant_id" => id}) do
    with {:ok, tenant_id} <- path_id(id, "ten", :tenant_not_found),
         {:ok, custody} <- found(TenantLifecycle.key_custody(tenant_id)) do
      reply(conn, 200, custody_view(tenant_id, custody))
    else
      {:error, error} -> problem(conn, error)
    end
  end

  # OP-85
  # TN-21
  @spec set_key_custody(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def set_key_custody(conn, %{"tenant_id" => id}) do
    key_ref = conn.assigns.body["key_ref"]

    idempotent(conn, fn ->
      with {:ok, tenant_id} <- path_id(id, "ten", :tenant_not_found),
           {:ok, _set} <- found(custody(tenant_id, key_ref, conn)),
           {:ok, custody} <- found(TenantLifecycle.key_custody(tenant_id)) do
        {:ok, {200, custody_view(tenant_id, custody)}}
      end
    end)
  end

  defp custody(tenant_id, key_ref, conn) do
    case TenantLifecycle.set_key_custody(tenant_id, key_ref, actor(conn, installation: true)) do
      {:error, %Relay.Error{code: :invalid_key_ref, message: message}} ->
        {:error, field("/key_ref", "invalid_format", message)}

      {:error, %Relay.Error{code: :tenant_closed}} ->
        {:error, Relay.Error.new(:resource_conflict, "the tenant is closed")}

      other ->
        other
    end
  end

  defp custody_view(tenant_id, custody) do
    %{
      "object" => "tenant_key_custody",
      "tenant_id" => Relay.ExternalId.encode("ten", tenant_id),
      "key_ref" => custody.key_ref,
      "keys_under_key" => custody.keys,
      "keys_under_other" => custody.other
    }
  end

  # OP-86
  @spec closure(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def closure(conn, %{"tenant_id" => id}) do
    with {:ok, tenant_id} <- path_id(id, "ten", :tenant_not_found),
         {:ok, closure} <- found(TenantLifecycle.closure(tenant_id)) do
      reply(conn, 200, closure_view(closure))
    else
      {:error, error} -> problem(conn, error)
    end
  end

  # OP-86
  # OP-26
  # TN-21
  @spec request_closure(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request_closure(conn, %{"tenant_id" => id}) do
    body = conn.assigns.body

    idempotent(conn, fn ->
      with {:ok, tenant_id} <- path_id(id, "ten", :tenant_not_found),
           attrs = %{reason: body["reason"], formats: body["formats"]},
           {:ok, closure} <-
             found(
               TenantLifecycle.request_closure(
                 tenant_id,
                 attrs,
                 actor(conn, installation: true),
                 step_up_ref(conn)
               )
             ) do
        {:ok, {201, closure_view(closure)}}
      end
    end)
  end

  # OP-86
  # TN-21
  @spec confirm_closure(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm_closure(conn, %{"tenant_id" => id}) do
    ref = conn.assigns.body["confirmation_ref"]

    idempotent(conn, fn ->
      with {:ok, tenant_id} <- path_id(id, "ten", :tenant_not_found),
           operator = actor(conn, installation: true),
           {:ok, _closure} <- found(TenantLifecycle.confirm_closure(tenant_id, ref, operator)),
           {:ok, closure} <- found(TenantLifecycle.closure(tenant_id)) do
        {:ok, {200, closure_view(closure)}}
      end
    end)
  end

  # OP-86
  # OP-26
  # TN-21
  @spec shred(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def shred(conn, %{"tenant_id" => id}) do
    idempotent(conn, fn ->
      with {:ok, tenant_id} <- path_id(id, "ten", :tenant_not_found),
           operator = actor(conn, installation: true),
           ref = step_up_ref(conn),
           {:ok, shredded} <- found(TenantLifecycle.shred(tenant_id, operator, ref)),
           {:ok, closure} <- found(TenantLifecycle.closure(tenant_id)) do
        {:ok, {200, Map.put(closure_view(closure), "shredded", shredded["shredded"])}}
      end
    end)
  end

  defp found({:error, %Relay.Error{code: :not_found}}),
    do: {:error, Relay.Error.new(:tenant_not_found, "no such tenant")}

  defp found(result), do: result

  defp closure_view(closure) do
    %{
      "object" => "tenant_closure",
      "tenant_id" => Relay.ExternalId.encode("ten", closure["tenant_id"]),
      "state" => closure["state"],
      "reason" => closure["reason"],
      "formats" => closure["formats"],
      "export_ready_at" => closure["export_ready_at"],
      "shred_after" => closure["shred_after"],
      "confirmed_at" => closure["confirmed_at"],
      "confirmation_ref" => closure["confirmation_ref"],
      "shred_started_at" => closure["shred_started_at"],
      "shredded_at" => closure["shredded_at"],
      "files" => Enum.map(closure["files"] || [], &file_view/1),
      "links_expire_at" => closure["links_expire_at"],
      "created_at" => closure["created_at"]
    }
  end

  defp file_view(file),
    do: Map.take(file, ~w(environment kind format key rows bytes sha256 url))
end
