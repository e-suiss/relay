defmodule RelayWeb.Operator.FaultInjectionController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.FaultInjection
  alias RelayWeb.Operator.Json

  @max_ttl_s 3_600

  # OP-92
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    include_inactive = params["include_inactive"] == "true"

    with {:ok, limit, after_id} <- page_params(conn),
         {:ok, records} <-
           FaultInjection.list(include_inactive: include_inactive, limit: 1_000) do
      rows =
        for record <- records,
            after_id == nil or record.id < after_id,
            do: %{"id" => record.id, "record" => record}

      page(conn, Enum.take(rows, limit + 1), limit, &Json.fault_injection(&1["record"]))
    else
      {:error, %Relay.Error{} = error} -> problem(conn, error)
      {:error, code} -> problem(conn, unavailable(code))
    end
  end

  # OP-92
  # OP-44
  # OP-78
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    body = conn.assigns.body

    with {:ok, ttl} <- ttl(body["ttl"]),
         {:ok, scope_kind, tenant_id} <- scope(body["tenant_id"]) do
      spec = %{
        scope_kind: scope_kind,
        tenant_id: tenant_id,
        environment: body["environment"],
        channel: body["channel"],
        provider: body["provider"],
        kind: body["kind"],
        rate_percent: body["rate_percent"],
        delay_ms: body["delay_ms"],
        reason: body["reason"],
        ttl_seconds: ttl
      }

      idempotent(conn, fn -> spec |> FaultInjection.engage(operator(conn)) |> answer() end)
    else
      {:error, error} -> problem(conn, error)
    end
  end

  # OP-92
  # OP-44
  @spec clear(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def clear(conn, %{"fault_injection_id" => id}) do
    idempotent(conn, fn ->
      with {:ok, id} <- path_id(id, "fij", :fault_injection_not_found) do
        case FaultInjection.clear(id, conn.assigns.body["reason"], operator(conn)) do
          {:ok, %{id: external}} -> shown(external, 200)
          {:error, code} -> {:error, error(code)}
        end
      end
    end)
  end

  defp answer({:ok, %{result: :engaged, id: id}}), do: shown(id, 201)
  defp answer({:ok, %{result: :exists, id: id}}), do: shown(id, 200)
  defp answer({:error, code}), do: {:error, error(code)}

  defp shown(id, status) do
    case FaultInjection.show(id) do
      {:ok, record} -> {:ok, {status, Json.fault_injection(record)}}
      {:error, code} -> {:partial, error(code)}
    end
  end

  defp operator(conn) do
    session = conn.assigns.operator_session
    %{kind: :installation_operator, ref: session.subject, access_record_ref: step_up_ref(conn)}
  end

  defp ttl(text) do
    case duration(text) do
      {:ok, seconds} when seconds <= @max_ttl_s -> {:ok, seconds}
      _ -> {:error, field("/ttl", "invalid_format", "an ISO 8601 duration of at most PT1H")}
    end
  end

  defp scope(nil), do: {:ok, :installation, nil}

  defp scope(text) do
    with {:ok, id} <- body_id(text, "ten", "/tenant_id"), do: {:ok, :tenant, id}
  end

  defp error(:not_found), do: Relay.Error.new(:fault_injection_not_found, "not found")
  defp error(:invalid_id), do: Relay.Error.new(:fault_injection_not_found, "not found")

  defp error(:not_permitted),
    do:
      field(
        "/environment",
        "not_allowed",
        "fault injection targets the test environment, or live only in chaos mode"
      )

  defp error(:invalid_delay),
    do:
      field(
        "/delay_ms",
        "not_allowed",
        "delay_ms belongs to added_latency (at most 10000) and delayed_delivery_report only"
      )

  defp error(code) when code in [:invalid_channel, :invalid_provider],
    do: field("/kind", "not_allowed", "iys_pull_stalled takes no channel or provider")

  defp error(:reason_required), do: field("/reason", "required", "a reason is required")
  defp error(code) when is_atom(code), do: unavailable(code)

  defp unavailable(code),
    do: Relay.Error.new(:service_unavailable, "fault injections cannot be read (#{code})")
end
