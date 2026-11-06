defmodule RelayWeb.Operator.ChannelController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.Api.ChannelOperations
  alias Relay.Operators.Authz

  # C-45
  # TN-21
  # TN-26
  @spec create_account(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_account(conn, _params) do
    run(conn, fn scope ->
      installation? = installation_operator?(conn)
      ChannelOperations.create_account(scope, conn.assigns.body, actor(conn), installation?)
    end)
  end

  # C-45
  # TN-21
  # OP-73
  @spec archive_account(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive_account(conn, %{"provider_account_id" => text}) do
    with_id(conn, text, "pva", :provider_account_not_found, fn scope, id ->
      ChannelOperations.archive_account(scope, id, actor(conn))
    end)
  end

  # TN-21
  # TN-26 (5)
  @spec rotate_credential(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rotate_credential(conn, %{"provider_account_id" => text}) do
    with_id(conn, text, "pva", :provider_account_not_found, fn scope, id ->
      body = conn.assigns.body
      ChannelOperations.rotate_credential(scope, id, body, step_up_ref(conn), actor(conn))
    end)
  end

  # C-25
  @spec review_sender(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def review_sender(conn, %{"sender_identity_id" => text}) do
    with_id(conn, text, "snd", :sender_identity_not_found, fn scope, id ->
      state = conn.assigns.body["approval_state"]
      ChannelOperations.review_sender(scope, id, state, actor(conn))
    end)
  end

  # TN-10
  # TN-21
  @spec suspend_sender(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def suspend_sender(conn, %{"sender_identity_id" => text}) do
    with_id(conn, text, "snd", :sender_identity_not_found, fn scope, id ->
      rule_id = conn.assigns.body["rule_id"]
      ChannelOperations.suspend_sender(scope, id, rule_id, actor(conn, installation: true))
    end)
  end

  # TN-10
  # TN-21
  @spec resume_sender(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resume_sender(conn, %{"sender_identity_id" => text}) do
    with_id(conn, text, "snd", :sender_identity_not_found, fn scope, id ->
      ChannelOperations.suspend_sender(scope, id, nil, actor(conn, installation: true))
    end)
  end

  # C-26
  # TN-21
  # TN-26
  @spec create_channel_identity(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_channel_identity(conn, _params) do
    run(conn, fn scope ->
      ChannelOperations.create_channel_identity(scope, conn.assigns.body, actor(conn))
    end)
  end

  # C-26
  # TN-21
  # TN-26 (5)
  @spec rotate_secret(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rotate_secret(conn, %{"channel_identity_id" => text}) do
    with_id(conn, text, "chi", :channel_identity_not_found, fn scope, id ->
      ChannelOperations.rotate_channel_identity(scope, id, conn.assigns.body, actor(conn))
    end)
  end

  defp with_id(conn, text, prefix, not_found, work) do
    case path_id(text, prefix, not_found) do
      {:ok, id} -> run(conn, &work.(&1, id))
      {:error, error} -> problem(conn, error)
    end
  end

  defp run(conn, work) do
    case conn.assigns.operator_scope do
      %Relay.Scope{} = scope -> idempotent(conn, fn -> work.(scope) end)
      nil -> problem(conn, tenant_required())
    end
  end

  defp installation_operator?(conn) do
    grants = conn.assigns.operator_session.grants
    Authz.installation_operator?(grants, Relay.Operators.installation_tenant_id())
  end

  defp tenant_required do
    Relay.Error.new(:validation_failed, "the tenant context headers are invalid", %{
      errors: [
        %{
          pointer: "/headers/relay-tenant",
          code: "required",
          detail: "Relay-Tenant and Relay-Environment"
        }
      ]
    })
  end
end
