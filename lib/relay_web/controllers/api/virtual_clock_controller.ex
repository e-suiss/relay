defmodule RelayWeb.Api.VirtualClockController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Duration
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  @max_step_ms 366 * 86_400_000

  # API-63
  # X-27
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    case Relay.Platform.virtual_clock(conn.assigns.scope) do
      {:ok, {:ok, offset, now}} -> Work.answer(conn, {:ok, {200, [], view(offset, now)}})
      {:ok, :not_test_environment} -> Response.problem(conn, mismatch())
      {:error, _reason} -> Response.problem(conn, Relay.Error.new(:service_unavailable, "retry"))
    end
  end

  # API-63
  # TN-8
  # X-27
  @spec advance(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def advance(conn, _params) do
    scope = conn.assigns.scope
    by = conn.assigns.body["by"]
    actor = Work.actor(conn)

    case Duration.to_ms(by) do
      {:ok, ms} when ms > 0 and ms <= @max_step_ms ->
        digest = Work.digest(scope, "virtual_clock.advanced", by)

        Work.idempotent(conn, fn _status -> advanced(scope, ms, digest, actor) end)

      _invalid ->
        Response.problem(conn, invalid_step())
    end
  end

  defp advanced(scope, ms, digest, actor) do
    case Relay.Platform.advance_virtual_clock_here(scope, ms, digest, actor) do
      {:advanced, offset, now} -> {:ok, {200, [], view(offset, now)}}
      :not_test_environment -> {:error, mismatch()}
      _invalid -> {:error, invalid_step()}
    end
  end

  defp view(offset, now),
    do: %{"object" => "virtual_clock", "offset_ms" => offset, "business_now" => now}

  defp mismatch,
    do: Relay.Error.new(:auth_environment_mismatch, "the virtual clock exists only in test")

  defp invalid_step do
    error = %{
      pointer: "/by",
      code: "invalid_format",
      detail: "a forward step of 366 days at most"
    }

    Relay.Error.new(:validation_failed, "the step is invalid", %{errors: [error]})
  end
end
