defmodule RelayWeb.Api.KillSwitchController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.KillSwitches
  alias Relay.Tenancy.KillSwitch
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

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
  # TN-45
  # API-79 (6)
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    ref = Work.actor(conn).ref

    case KillSwitches.engage_spec(scope, body) do
      {:ok, spec} -> written(conn, fn -> KillSwitches.engage(spec, ref) end)
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
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, %{"kill_switch_id" => id}) do
    %{scope: scope, body: body} = conn.assigns
    ref = Work.actor(conn).ref

    case KillSwitches.fetch(scope, id) do
      {:ok, record} -> written(conn, fn -> KillSwitches.replace(record, body, ref) end)
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # TN-22
  # API-79 (6)
  @spec release(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def release(conn, %{"kill_switch_id" => id}), do: operator_only(conn, id)

  # TN-22
  # TN-40
  @spec resume(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resume(conn, %{"kill_switch_id" => id}), do: operator_only(conn, id)

  # TN-47
  @spec cancel_paused(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel_paused(conn, %{"kill_switch_id" => id}), do: operator_only(conn, id)

  defp operator_only(conn, id) do
    case KillSwitches.fetch(conn.assigns.scope, id) do
      {:ok, _record} -> Response.problem(conn, KillSwitches.operator_session_required())
      {:error, error} -> Response.problem(conn, error)
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
            {:error, error}
        end
      end)

    case Process.delete(@generation) do
      nil -> :ok
      generation -> KillSwitch.signal(generation)
    end

    conn
  end
end
