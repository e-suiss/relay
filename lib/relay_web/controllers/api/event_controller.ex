defmodule RelayWeb.Api.EventController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Cancels
  alias Relay.Api.CloudEvent
  alias Relay.Api.Events
  alias Relay.Api.Queries
  alias RelayWeb.Api.Admission
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # API-19
  # API-28
  # API-31
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    ctx = Work.context(conn)
    body = conn.assigns.body

    case conn.assigns[:cloudevent] || conn.assigns.media_type do
      :binary ->
        with {:ok, event} <- CloudEvent.from_binary(conn.req_headers, body),
             {:ok, prepared} <- CloudEvent.prepare(ctx, event) do
          single(conn, ctx, prepared)
        else
          {:error, error} -> Response.problem(conn, error)
        end

      "application/cloudevents+json" ->
        prepared(conn, ctx, CloudEvent.prepare(ctx, body))

      "application/cloudevents-batch+json" ->
        rows =
          for {event, index} <- Enum.with_index(body),
              do: {index, nil, CloudEvent.prepare(ctx, event)}

        batch(conn, ctx, rows)

      "application/json" ->
        prepared(conn, ctx, Events.prepare(ctx, body))
    end
  end

  # API-32
  # API-33
  # API-34
  @spec batch(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def batch(conn, _params) do
    ctx = Work.context(conn)

    rows =
      for {row, index} <- Enum.with_index(conn.assigns.body["events"]),
          do: {index, row["ref"], Events.prepare(ctx, Map.delete(row, "ref"))}

    batch(conn, ctx, rows)
  end

  defp batch(conn, ctx, rows) do
    problem = Work.problem(conn)
    Work.idempotent(conn, fn _status -> Events.batch(rows, ctx, problem) end)
  end

  defp prepared(conn, ctx, {:ok, prepared}), do: single(conn, ctx, prepared)
  defp prepared(conn, _ctx, {:error, error}), do: Response.problem(conn, error)

  # T-35
  # OP-7
  defp single(conn, ctx, prepared) do
    {class, channels} = Events.admission(prepared)

    case Admission.check(class, channels) do
      :ok -> Work.idempotent(conn, fn _status -> accept(prepared, ctx) end)
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp accept(prepared, ctx) do
    with {:ok, body} <- Events.accept(prepared, ctx),
         do: {:ok, {202, [{"location", "/v1/events/" <> body["id"]}], body}}
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"event_id" => text}) do
    case Work.path_id(text, "evt", :event_not_found) do
      {:ok, id} -> Work.answer(conn, Queries.event(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # API-57
  @spec cancel(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel(conn, %{"event_id" => text}) do
    case Work.path_id(text, "evt", :event_not_found) do
      {:ok, id} ->
        reason = (conn.assigns.body || %{})["reason"]
        actor = Work.actor(conn)
        Work.idempotent(conn, fn _status -> Cancels.event(id, reason, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # API-57
  # API-58
  @spec cancel_by_key(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel_by_key(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case recipients(scope, body["recipients"]) do
      {:ok, indexes} ->
        Work.idempotent(conn, fn _status -> Cancels.by_key(body, indexes, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  defp recipients(_scope, nil), do: {:ok, nil}

  defp recipients(scope, external_ids) do
    case Queries.indexes(scope, external_ids) do
      {:ok, indexes} -> {:ok, indexes}
      {:error, _reason} -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end
end
