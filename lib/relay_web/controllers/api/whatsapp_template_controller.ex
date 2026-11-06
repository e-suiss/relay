defmodule RelayWeb.Api.WhatsappTemplateController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.WhatsappTemplates
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # CH-57
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, WhatsappTemplates.list(scope, page, operation.endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # CH-57
  # TP-23
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    case WhatsappTemplates.prepare(conn.assigns.body) do
      {:ok, row} -> Work.idempotent(conn, fn _status -> WhatsappTemplates.register(row) end)
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # CH-57
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"whatsapp_template_id" => text}) do
    case Work.path_id(text, "wtp", :whatsapp_template_not_found) do
      {:ok, id} -> Work.answer(conn, WhatsappTemplates.get(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
