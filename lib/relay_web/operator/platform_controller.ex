defmodule RelayWeb.Operator.PlatformController do
  @moduledoc false

  use RelayWeb, :api_controller

  import RelayWeb.Operator.Helpers

  alias Relay.Operators
  alias Relay.Operators.Admin
  alias Relay.Operators.Suspension
  alias Relay.Tenancy.KillSwitch
  alias RelayWeb.Operator.Json

  @queues "/v1/operator/queues"

  # TN-41
  # TN-45
  @spec kill_switches(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def kill_switches(conn, params) do
    include_released = params["include_released"] == "true"

    with {:ok, limit, after_id} <- page_params(conn),
         {:ok, records} <-
           KillSwitch.list(Operators.installation_scope(),
             include_released: include_released,
             after: after_id,
             limit: limit + 1
           ) do
      rows = for record <- records, record.scope_kind == :platform, do: Map.from_struct(record)
      page(conn, rows, limit, &Json.kill_switch/1)
    else
      {:error, %Relay.Error{} = error} -> problem(conn, error)
    end
  end

  # TN-36
  # TN-41
  # TN-42
  # TN-21
  @spec engage(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def engage(conn, _params) do
    body = conn.assigns.body
    sensitive = body["message_class"] == "security" or body["no_ttl"] == true

    with {:ok, conn} <- if(sensitive, do: step_up(conn), else: {:ok, conn}),
         {:ok, expires_at} <- expiry(body),
         {:ok, state} <- state(body),
         {:ok, target} <- target(body) do
      ref = step_up_ref(conn)

      spec = %{
        scope_kind: :platform,
        channel: body["channel"],
        target: target,
        message_class: body["message_class"],
        security_approval: if(body["message_class"] == "security", do: ref),
        state: state,
        reason: body["reason"],
        ticket: body["ticket_ref"],
        expires_at: expires_at,
        no_ttl_approval: if(expires_at == nil, do: ref)
      }

      idempotent(conn, fn ->
        spec |> KillSwitch.engage(operator(conn)) |> answer(201)
      end)
    else
      {:error, error} -> problem(conn, error)
    end
  end

  # TN-22
  # TN-70 (1)
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, %{"kill_switch_id" => id}) do
    body = conn.assigns.body

    with {:ok, conn} <- if(body["no_ttl"] == true, do: step_up(conn), else: {:ok, conn}),
         {:ok, expires_at} <- expiry(body),
         {:ok, state} <- state(body),
         {:ok, record} <- platform_record(id),
         {:ok, conn} <- relax_step_up(conn) do
      change = %{
        reason: body["reason"],
        state: state,
        expires_at: expires_at,
        no_ttl_approval: step_up_ref(conn),
        relax_approval: step_up_ref(conn)
      }

      idempotent(conn, fn ->
        record.id |> KillSwitch.replace(change, operator(conn)) |> answer(201)
      end)
    else
      {:error, error} -> problem(conn, error)
    end
  end

  defp relax_step_up(conn) do
    if Operators.step_up_fresh?(conn.assigns.operator_session),
      do: step_up(conn),
      else: {:ok, conn}
  end

  # TN-22
  # TN-40
  @spec release(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def release(conn, %{"kill_switch_id" => id}) do
    case platform_record(id) do
      {:ok, record} ->
        change = %{reason: conn.assigns.body["reason"], relax_approval: step_up_ref(conn)}

        idempotent(conn, fn -> release_record(conn, record.id, change) end)

      {:error, error} ->
        problem(conn, error)
    end
  end

  defp release_record(conn, id, change) do
    case KillSwitch.release(id, change, operator(conn)) do
      {:ok, _result} -> released(id)
      {:error, code} -> {:error, kill_switch_error(code)}
    end
  end

  # API-14
  defp released(id) do
    case KillSwitch.list(Operators.installation_scope(), include_released: true, limit: 1_000) do
      {:ok, records} ->
        record = Enum.find(records, &(&1.id == id))
        {:ok, {200, Json.kill_switch(Map.from_struct(record))}}

      {:error, error} ->
        {:partial, error}
    end
  end

  defp platform_record(id) do
    with {:ok, id} <- path_id(id, "ksw", :kill_switch_not_found),
         {:ok, %{scope_kind: :platform} = record} <- KillSwitch.show(id) do
      {:ok, record}
    else
      {:error, %Relay.Error{} = error} -> {:error, error}
      _ -> {:error, Relay.Error.new(:kill_switch_not_found, "no such platform kill switch")}
    end
  end

  defp operator(conn) do
    session = conn.assigns.operator_session
    %{kind: :installation_operator, ref: session.subject, access_record_ref: step_up_ref(conn)}
  end

  # API-14
  defp answer({:ok, %{id: id}}, status) do
    case KillSwitch.show(id) do
      {:ok, record} -> {:ok, {status, Json.kill_switch(Map.from_struct(record))}}
      {:error, code} -> {:partial, kill_switch_error(code)}
    end
  end

  defp answer({:error, code}, _status), do: {:error, kill_switch_error(code)}

  defp kill_switch_error(:not_found), do: Relay.Error.new(:kill_switch_not_found, "not found")
  defp kill_switch_error(:already_released), do: Relay.Error.new(:resource_conflict, "released")
  defp kill_switch_error(:exists), do: Relay.Error.new(:resource_conflict, "already engaged")

  defp kill_switch_error(code)
       when code in [
              :relax_approval_required,
              :security_approval_required,
              :no_ttl_approval_required
            ],
       do: Operators.step_up_required()

  defp kill_switch_error(code) when is_atom(code),
    do: field("/", "invalid_format", "the kill switch is not valid (#{code})")

  defp expiry(%{"no_ttl" => true}), do: {:ok, nil}

  defp expiry(%{"ttl" => ttl}) do
    case duration(ttl) do
      {:ok, seconds} -> {:ok, DateTime.add(Relay.Clock.utc_now(), seconds, :second)}
      :error -> {:error, field("/ttl", "invalid_format", "an ISO 8601 duration")}
    end
  end

  defp expiry(_body), do: {:error, field("/ttl", "required", "a TTL or no_ttl is required")}

  defp state(%{"state" => "canary", "canary_percent" => percent}) when is_integer(percent),
    do: {:ok, {:canary, percent}}

  defp state(%{"state" => "canary"}),
    do: {:error, field("/canary_percent", "required", "canary needs canary_percent")}

  defp state(%{"state" => "paused_until", "paused_until" => until}) do
    case timestamp(until) do
      {:ok, at} -> {:ok, {:paused_until, at}}
      :error -> {:error, field("/paused_until", "invalid_format", "an RFC 3339 time")}
    end
  end

  defp state(%{"state" => "paused_until"}),
    do: {:error, field("/paused_until", "required", "paused_until needs a time")}

  defp state(_body), do: {:ok, :off}

  defp target(%{"target_kind" => kind, "target_ref" => ref})
       when kind in ["provider_account", "template"] and is_binary(ref),
       do:
         {:ok,
          {Map.fetch!(%{"provider_account" => :provider_account, "template" => :template}, kind),
           ref}}

  defp target(%{"target_kind" => kind}) when kind in ["provider_account", "template"],
    do: {:error, field("/target_ref", "required", "the target needs target_ref")}

  defp target(_body), do: {:ok, :all}

  # X-4
  # TN-23
  @spec tenants(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def tenants(conn, params) do
    with {:ok, limit, after_id} <- page_params(conn),
         {:ok, status} <- status(params["status"]),
         {:ok, rows} <-
           Admin.tenants(actor(conn, installation: true), %{
             status: status,
             after_id: after_id,
             limit: limit + 1
           }) do
      page(conn, rows, limit, &Json.tenant(&1, nil))
    else
      {:error, error} -> problem(conn, error)
    end
  end

  defp status(nil), do: {:ok, nil}
  defp status(status) when status in ["active", "suspended", "closed"], do: {:ok, status}

  defp status(_status),
    do: {:error, field("/query/status", "unsupported_value", "a tenant status")}

  @spec tenant(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def tenant(conn, %{"tenant_id" => id}) do
    with {:ok, tenant_id} <- path_id(id, "ten", :tenant_not_found),
         {:ok, [row]} <- Admin.tenants(actor(conn, installation: true), %{tenant_id: tenant_id}),
         {:ok, suspensions} <- Suspension.list(tenant_id) do
      reply(conn, 200, Json.tenant(row, suspensions))
    else
      {:ok, []} -> problem(conn, Relay.Error.new(:tenant_not_found, "no such tenant"))
      {:error, error} -> problem(conn, error)
    end
  end

  # TN-10
  # TN-71
  # TN-21
  @spec suspend(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def suspend(conn, %{"tenant_id" => id}) do
    body = conn.assigns.body

    idempotent(conn, fn ->
      with {:ok, tenant_id} <- path_id(id, "ten", :tenant_not_found),
           {:ok, subtenant_id} <- optional_id(body["subtenant_id"], "stn", "/subtenant_id"),
           {:ok, effective_at} <- optional_time(body["effective_at"]),
           attrs = %{
             ground: body["ground"],
             reason: body["reason"],
             subtenant_id: subtenant_id,
             effective_at: effective_at
           },
           {:ok, row} <-
             Suspension.suspend(
               tenant_id,
               attrs,
               actor(conn, installation: true),
               step_up_ref(conn)
             ) do
        {:ok, {201, Json.suspension(row)}}
      end
    end)
  end

  # TN-10
  # TN-22
  @spec resume(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resume(conn, %{"tenant_id" => id}) do
    body = conn.assigns.body

    idempotent(conn, fn ->
      with {:ok, tenant_id} <- path_id(id, "ten", :tenant_not_found),
           {:ok, subtenant_id} <- optional_id(body["subtenant_id"], "stn", "/subtenant_id"),
           {:ok, row} <-
             Suspension.resume(
               tenant_id,
               subtenant_id,
               body["reason"],
               actor(conn, installation: true),
               step_up_ref(conn)
             ) do
        {:ok, {200, Json.suspension(row)}}
      end
    end)
  end

  defp optional_id(nil, _prefix, _pointer), do: {:ok, nil}
  defp optional_id(value, prefix, pointer), do: body_id(value, prefix, pointer)

  defp optional_time(nil), do: {:ok, nil}

  defp optional_time(text) do
    case timestamp(text) do
      {:ok, at} -> {:ok, at}
      :error -> {:error, field("/effective_at", "invalid_format", "an RFC 3339 time")}
    end
  end

  # X-7
  # T-87
  @spec queue_panel(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def queue_panel(conn, _params),
    do: reply(conn, 200, %{"object" => "queue_panel", "url" => @queues})
end
