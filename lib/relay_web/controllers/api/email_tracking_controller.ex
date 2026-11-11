defmodule RelayWeb.Api.EmailTrackingController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.EmailTracking
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  @category ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @template ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/

  # DS-29
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    case target(conn, params) do
      {:ok, target, key} -> Work.answer(conn, EmailTracking.get(conn.assigns.scope, target, key))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # CH-43
  # DS-29
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case target(conn, params) do
      {:ok, target, key} ->
        Work.idempotent(conn, fn _status ->
          EmailTracking.put(scope, target, key, body, actor)
        end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  defp target(%{private: %{relay_target: "category"}}, %{"category_key" => key}) do
    if Regex.match?(@category, key),
      do: {:ok, "category", key},
      else: {:error, Relay.Error.new(:category_not_found, "no category has this key")}
  end

  defp target(%{private: %{relay_target: "template"}}, %{"template_key" => key}) do
    if Regex.match?(@template, key) and byte_size(key) <= 100,
      do: {:ok, "template", key},
      else: {:error, Relay.Error.new(:template_not_found, "no template has this key")}
  end
end
