defmodule RelayWeb.Api.KillSwitchController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.KillSwitches
  alias Relay.Tenancy.KillSwitch
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work
  alias RelayWeb.Auth.OperatorSession

  @generation {__MODULE__, :generation}

  # TN-41
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    %{scope: scope, operation: operation} = conn.assigns
    include = params["include_released"] in ["true", true]

    case Work.page(conn) do
      {:ok, page} ->
        Work.answer(conn, KillSwitches.list(scope, include, page, operation.endpoint))

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # TN-41
  # TN-42
  # TN-45
  # API-79 (6)
  # X-47
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    sensitive = body["message_class"] == "security" or body["no_ttl"] == true

    with {:ok, conn} <- step_up_if(conn, Work.operator?(conn) and sensitive),
         {:ok, spec} <- KillSwitches.engage_spec(scope, body, spec_opts(conn)) do
      written(conn, fn -> KillSwitches.engage(spec, actor(conn)) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"kill_switch_id" => id}) do
    case KillSwitches.fetch(conn.assigns.scope, id) do
      {:ok, record} -> Work.answer(conn, {:ok, {200, [], KillSwitches.view(record)}})
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # TN-22
  # API-79 (6)
  # X-47
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, %{"kill_switch_id" => id}) do
    %{scope: scope, body: body} = conn.assigns
    operator = Work.operator?(conn)

    with {:ok, record} <- KillSwitches.fetch(scope, id),
         {:ok, conn} <- step_up_if(conn, operator and body["no_ttl"] == true),
         {:ok, conn} <- step_up_if(conn, operator and fresh?(conn)) do
      written(conn, fn ->
        KillSwitches.replace(record, body, actor(conn), approval(conn))
      end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # TN-22
  # API-79 (6)
  # X-47
  @spec release(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def release(conn, %{"kill_switch_id" => id}) do
    operator_only(conn, id, fn record, reason ->
      KillSwitches.release(record, reason, actor(conn), approval(conn))
    end)
  end

  # TN-22
  # TN-40
  # X-47
  @spec resume(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resume(conn, %{"kill_switch_id" => id}) do
    operator_only(conn, id, fn record, reason ->
      KillSwitches.resume(record, reason, actor(conn), approval(conn))
    end)
  end

  # TN-47
  # X-47
  @spec cancel_paused(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel_paused(conn, %{"kill_switch_id" => id}) do
    operator_only(conn, id, fn record, reason ->
      KillSwitches.cancel_paused(record, reason, actor(conn))
    end)
  end

  defp operator_only(conn, id, command) do
    case KillSwitches.fetch_any(conn.assigns.scope, id) do
      {:ok, record} -> run_operator_only(conn, record, command)
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp run_operator_only(conn, record, command) do
    reason = conn.assigns.body["reason"]

    if Work.operator?(conn),
      do: Work.spanning(conn, fn -> answer(command.(record, reason)) end),
      else: Response.problem(conn, KillSwitches.operator_session_required())
  end

  defp answer({:error, %Relay.Error{code: :auth_step_up_required}}),
    do: {:error, OperatorSession.step_up_required()}

  defp answer(result), do: result

  defp spec_opts(conn) do
    if Work.operator?(conn),
      do: [operator: true, approval: approval(conn)],
      else: []
  end

  defp step_up_if(conn, false), do: {:ok, conn}

  defp step_up_if(conn, true) do
    %{principal: principal, operation: operation} = conn.assigns

    case OperatorSession.require_step_up(principal, operation, conn.request_path) do
      {:ok, principal} -> {:ok, assign(conn, :principal, principal)}
      {:error, error} -> {:error, error}
    end
  end

  defp fresh?(conn), do: OperatorSession.step_up_fresh?(conn.assigns.principal)

  defp approval(conn) do
    if Work.operator?(conn), do: OperatorSession.step_up_ref(conn.assigns.principal)
  end

  # TN-48
  defp actor(conn) do
    actor = Work.actor(conn)

    case conn.assigns.principal do
      %{kind: :operator, operator: %{role: role}} ->
        %{
          kind: role,
          ref: actor.ref,
          on_behalf_of_ref: actor.on_behalf_of_ref,
          access_record_ref: actor.access_record_ref
        }

      _client ->
        %{kind: :api_client, ref: actor.ref}
    end
  end

  defp written(conn, write) do
    Process.delete(@generation)

    conn =
      Work.idempotent(conn, fn _status ->
        case write.() do
          {:ok, answer, generation} ->
            Process.put(@generation, generation)
            {:ok, answer}

          {:error, error} ->
            answer({:error, error})
        end
      end)

    case Process.delete(@generation) do
      nil -> :ok
      generation -> KillSwitch.signal(generation)
    end

    conn
  end
end
