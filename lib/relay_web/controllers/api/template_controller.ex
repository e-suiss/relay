defmodule RelayWeb.Api.TemplateController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Previews
  alias Relay.Api.Templates
  alias RelayWeb.Api.Level
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  @key ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
  @sources ["draft", "live"]

  # API-56
  # API-69
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, subtenant_id} <- Level.subtenant(conn, Level.invalid()),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, Templates.list(scope, subtenant_id, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # TP-1
  # TP-48
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case Level.subtenant(conn, Level.invalid()) do
      {:ok, subtenant_id} ->
        at = %{key: body["key"], subtenant_id: subtenant_id}
        Work.idempotent(conn, fn _status -> Templates.create(scope, at, body, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"template_key" => key}) do
    case at(conn, key) do
      {:ok, at} -> Work.answer(conn, Templates.get(conn.assigns.scope, at))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # TP-31
  # T-59 (7)
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, %{"template_key" => key}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with_at(conn, key, fn at, expected ->
      Work.idempotent(conn, fn _status -> Templates.replace(scope, at, body, expected, actor) end)
    end)
  end

  # TP-31
  # TP-32
  @spec publish(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def publish(conn, %{"template_key" => key}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with_at(conn, key, fn at, expected ->
      prepared = Templates.prepare_publish(scope, at, body)
      run_prepared(conn, prepared, &Templates.publish(scope, at, &1, expected, actor))
    end)
  end

  # TP-48
  @spec archive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive(conn, %{"template_key" => key}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    with_at(conn, key, fn at, expected ->
      Work.idempotent(conn, fn _status -> Templates.archive(scope, at, expected, actor) end)
    end)
  end

  # API-56
  # TP-31
  @spec versions(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def versions(conn, %{"template_key" => key}) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, at} <- at(conn, key),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, Templates.versions(scope, at, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # TP-31
  @spec version(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def version(conn, %{"template_key" => key, "version" => number}) do
    with {:ok, at} <- at(conn, key),
         {:ok, number} <- number(number) do
      Work.answer(conn, Templates.version(conn.assigns.scope, at, number))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # TP-31
  @spec promote(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def promote(conn, %{"template_key" => key, "version" => number}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    case number(number) do
      {:ok, number} -> with_at(conn, key, &promote_at(conn, scope, actor, number, &1, &2))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # TP-30
  @spec translations(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def translations(conn, %{"template_key" => key}) do
    source = Map.get(conn.query_params, "source", "draft")

    with {:ok, at} <- at(conn, key),
         {:ok, source} <- source(source) do
      Work.answer(conn, Templates.translations(conn.assigns.scope, at, source))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # API-60
  # TP-38
  @spec preview(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def preview(conn, %{"template_key" => key}) do
    %{scope: scope, body: body} = conn.assigns

    case at(conn, key) do
      {:ok, at} -> Work.answer(conn, Previews.template(scope, at, body))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # TP-37
  # TP-52
  @spec producer(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def producer(conn, %{"template_key" => key}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case key(key) do
      {:ok, key} ->
        prepared = Templates.prepare_producer(scope, key, body)
        run_prepared(conn, prepared, &Templates.producer_publish(scope, &1, body, actor))

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  defp promote_at(conn, scope, actor, number, at, expected) do
    checked = Templates.prepare_promote(scope, at, number)

    run_prepared(conn, checked, fn _inputs ->
      Templates.promote(scope, at, number, expected, actor)
    end)
  end

  defp run_prepared(conn, {:ok, prepared}, fun),
    do: Work.idempotent(conn, fn _status -> fun.(prepared) end)

  defp run_prepared(conn, error, _fun), do: Work.idempotent(conn, fn _status -> error end)

  defp with_at(conn, key, fun) do
    with {:ok, at} <- at(conn, key),
         {:ok, expected} <- Work.if_match(conn, :required) do
      fun.(at, expected)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp at(conn, key) do
    with {:ok, key} <- key(key),
         {:ok, subtenant_id} <- Level.subtenant(conn, Templates.not_found()),
         do: {:ok, %{key: key, subtenant_id: subtenant_id}}
  end

  defp key(key) do
    if Regex.match?(@key, key) and byte_size(key) <= 100,
      do: {:ok, key},
      else: {:error, Templates.not_found()}
  end

  defp number(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 1 -> {:ok, n}
      _other -> {:error, Templates.version_not_found()}
    end
  end

  defp source(source) when source in @sources, do: {:ok, source}

  defp source(_source) do
    {:error,
     Relay.Error.new(:validation_failed, "the request breaks a field rule", %{
       errors: [%{pointer: "/source", code: "unsupported_value", detail: "draft or live"}]
     })}
  end
end
