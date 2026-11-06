defmodule RelayWeb.Api.ChannelController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.ChannelManagement
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  @params %{
    account: "provider_account_id",
    sender: "sender_identity_id",
    channel_identity: "channel_identity_id"
  }
  @not_found %{
    account: :provider_account_not_found,
    sender: :sender_identity_not_found,
    channel_identity: :channel_identity_not_found
  }

  # C-45
  # API-56
  @spec accounts(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def accounts(conn, _params), do: index(conn, :account)

  # C-45
  @spec account(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def account(conn, params), do: show(conn, :account, params)

  # C-45
  # CH-14
  # T-59 (7)
  @spec update_account(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_account(conn, params),
    do: update(conn, :account, params, &ChannelManagement.update_account/5)

  # CH-14
  # CH-52
  @spec verify_account(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def verify_account(conn, params),
    do: act(conn, :account, params, &ChannelManagement.verify_account/3)

  # C-25
  # API-56
  @spec senders(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def senders(conn, _params), do: index(conn, :sender)

  # C-25
  @spec create_sender(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_sender(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> ChannelManagement.create_sender(scope, body, actor) end)
  end

  # C-25
  @spec sender(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sender(conn, params), do: show(conn, :sender, params)

  # C-25
  # T-59 (7)
  @spec update_sender(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_sender(conn, params),
    do: update(conn, :sender, params, &ChannelManagement.update_sender/5)

  # C-25
  # OP-73
  @spec archive_sender(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive_sender(conn, params), do: archive(conn, :sender, params)

  # C-26
  # API-56
  @spec channel_identities(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def channel_identities(conn, _params), do: index(conn, :channel_identity)

  # C-26
  @spec channel_identity(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def channel_identity(conn, params), do: show(conn, :channel_identity, params)

  # C-26
  # T-59 (7)
  @spec update_channel_identity(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_channel_identity(conn, params),
    do: update(conn, :channel_identity, params, &ChannelManagement.update_channel_identity/5)

  # C-26
  # OP-73
  @spec archive_channel_identity(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive_channel_identity(conn, params), do: archive(conn, :channel_identity, params)

  defp index(conn, kind) do
    %{scope: scope, operation: %{endpoint: endpoint}} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, ChannelManagement.list(scope, kind, page, endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp show(conn, kind, params) do
    case path_id(kind, params) do
      {:ok, id} -> Work.answer(conn, ChannelManagement.get(conn.assigns.scope, kind, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp update(conn, kind, params, write) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with {:ok, id} <- path_id(kind, params),
         {:ok, expected} <- Work.if_match(conn, :required) do
      Work.idempotent(conn, fn _status -> write.(scope, id, body, expected, actor) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp archive(conn, kind, params),
    do: act(conn, kind, params, &ChannelManagement.archive(&1, kind, &2, &3))

  defp act(conn, kind, params, action) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    case path_id(kind, params) do
      {:ok, id} -> Work.idempotent(conn, fn _status -> action.(scope, id, actor) end)
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp path_id(kind, params) do
    text = Map.get(params, Map.fetch!(@params, kind), "")
    Work.path_id(text, ChannelManagement.prefix(kind), Map.fetch!(@not_found, kind))
  end
end
