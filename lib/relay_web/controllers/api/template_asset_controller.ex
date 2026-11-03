defmodule RelayWeb.Api.TemplateAssetController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.TemplateAssets
  alias RelayWeb.Api.Level
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  @key ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/

  # API-56
  # API-69
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns
    kind = kind(conn)

    with {:ok, subtenant_id} <- Level.subtenant(conn, Level.invalid()),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, TemplateAssets.list(kind, scope, subtenant_id, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # TP-35
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    kind = kind(conn)

    case Level.subtenant(conn, Level.invalid()) do
      {:ok, subtenant_id} ->
        Work.idempotent(conn, fn _status ->
          TemplateAssets.create(kind, scope, subtenant_id, body, actor)
        end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    kind = kind(conn)

    case at(conn, kind, params) do
      {:ok, at} -> Work.answer(conn, TemplateAssets.get(kind, conn.assigns.scope, at))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # TP-35
  # T-59 (7)
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    kind = kind(conn)

    with_at(conn, kind, params, fn at, expected ->
      Work.idempotent(conn, fn _status ->
        TemplateAssets.replace(kind, scope, at, body, expected, actor)
      end)
    end)
  end

  # TP-31
  # TP-32
  @spec publish(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def publish(conn, params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    kind = kind(conn)

    with_at(conn, kind, params, fn at, expected ->
      prepared = TemplateAssets.prepare_publish(kind, scope, at, body)

      Work.idempotent(conn, fn _status ->
        with {:ok, prepared} <- prepared,
             do: TemplateAssets.publish(kind, scope, at, prepared, expected, actor)
      end)
    end)
  end

  # TP-48
  @spec archive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive(conn, params) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)
    kind = kind(conn)

    with_at(conn, kind, params, fn at, expected ->
      Work.idempotent(conn, fn _status ->
        TemplateAssets.archive(kind, scope, at, expected, actor)
      end)
    end)
  end

  # API-56
  # TP-31
  @spec versions(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def versions(conn, params) do
    %{scope: scope, operation: operation} = conn.assigns
    kind = kind(conn)

    with {:ok, at} <- at(conn, kind, params),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, TemplateAssets.versions(kind, scope, at, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # TP-31
  @spec version(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def version(conn, %{"version" => number} = params) do
    kind = kind(conn)

    with {:ok, at} <- at(conn, kind, params),
         {:ok, number} <- number(kind, number) do
      Work.answer(conn, TemplateAssets.version(kind, conn.assigns.scope, at, number))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # TP-31
  @spec promote(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def promote(conn, %{"version" => number} = params) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)
    kind = kind(conn)

    case number(kind, number) do
      {:ok, number} ->
        with_at(conn, kind, params, fn at, expected ->
          checked = TemplateAssets.prepare_promote(kind, scope, at, number)

          Work.idempotent(conn, fn _status ->
            with :ok <- checked,
                 do: TemplateAssets.promote(kind, scope, at, number, expected, actor)
          end)
        end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  defp kind(conn), do: Map.fetch!(conn.private, :relay_kind)

  defp with_at(conn, kind, params, fun) do
    with {:ok, at} <- at(conn, kind, params),
         {:ok, expected} <- Work.if_match(conn, :required) do
      fun.(at, expected)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp at(conn, kind, params) do
    key = Map.get(params, "#{kind}_key", "")

    with {:ok, key} <- key(kind, key),
         {:ok, subtenant_id} <- Level.subtenant(conn, TemplateAssets.not_found(kind)),
         do: {:ok, %{key: key, subtenant_id: subtenant_id}}
  end

  defp key(kind, key) do
    if Regex.match?(@key, key) and byte_size(key) <= 100,
      do: {:ok, key},
      else: {:error, TemplateAssets.not_found(kind)}
  end

  defp number(kind, text) do
    case Integer.parse(text) do
      {n, ""} when n >= 1 -> {:ok, n}
      _other -> {:error, TemplateAssets.version_not_found(kind)}
    end
  end
end
