defmodule RelayWeb.Api.ProviderInvoiceController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.ProviderInvoices
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # OP-38
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: %{endpoint: endpoint}} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, ProviderInvoices.list(scope, page, endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # OP-38
  # OP-42
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> ProviderInvoices.create(scope, body, actor) end)
  end

  # OP-42
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    text = Map.get(params, "provider_invoice_id", "")

    case Work.path_id(text, ProviderInvoices.prefix(), :provider_invoice_not_found) do
      {:ok, id} -> Work.answer(conn, ProviderInvoices.get(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
