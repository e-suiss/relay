defmodule RelayWeb.Api.ReceiptController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  @time %{errors: [%{pointer: "/occurred_at", code: "invalid_format", detail: "RFC 3339"}]}

  # DS-13
  # DS-8
  @spec create_mine(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_mine(conn, _params) do
    %{principal: principal, body: body} = conn.assigns
    subscriber_id = principal.subscriber_id
    kind = if body["receipt"] == "displayed", do: :displayed, else: :clicked

    with {:ok, delivery_id} <- Work.path_id(body["delivery_id"], "dlv", :delivery_not_found),
         {:ok, at} <- occurred_at(body["occurred_at"]) do
      ref = Relay.ExternalId.encode("sub", subscriber_id)

      conn
      |> assign(:idempotency_endpoint, conn.assigns.operation.endpoint <> " " <> ref)
      |> Work.idempotent(fn _status ->
        record(subscriber_id, delivery_id, kind, at, body)
      end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp record(subscriber_id, delivery_id, kind, at, body) do
    case Relay.Engagement.record_receipt(subscriber_id, delivery_id, kind, at) do
      {:ok, _result} ->
        view = %{
          "object" => "push_receipt",
          "delivery_id" => body["delivery_id"],
          "receipt" => body["receipt"]
        }

        {:ok, {202, [], view}}

      {:error, :delivery_not_found} ->
        {:error, Relay.Error.new(:delivery_not_found, "no delivery has this id")}
    end
  end

  defp occurred_at(nil), do: {:ok, Relay.Clock.utc_now()}

  defp occurred_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} ->
        {:ok, at}

      _other ->
        {:error, Relay.Error.new(:validation_failed, "the request breaks a field rule", @time)}
    end
  end
end
