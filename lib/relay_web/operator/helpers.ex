defmodule RelayWeb.Operator.Helpers do
  @moduledoc """
  Shared steps of the operator controllers: answers, idempotent writes, cursor pages, path identifiers, the audit actor and the step-up of a conditionally sensitive operation.
  """

  alias Relay.Api.Cursor
  alias Relay.Api.Pagination
  alias Relay.Operators
  alias RelayWeb.Api.Response

  @doc "Sends a JSON body."
  @spec reply(Plug.Conn.t(), 100..599, map() | list()) :: Plug.Conn.t()
  def reply(conn, status, body), do: Response.json(conn, status, body)

  @doc "Sends the problem of an error."
  @spec problem(Plug.Conn.t(), Relay.Error.t()) :: Plug.Conn.t()
  def problem(conn, %Relay.Error{} = error), do: Response.problem(conn, error)

  # API-10
  @doc "Runs a write that carries its validated `Idempotency-Key` and answers its result; `work` returns `{:ok, {status, body}}` or `{:error, error}`. An operator write spans its own transactions, so its response is not stored for replay."
  @spec idempotent(Plug.Conn.t(), (-> {:ok, {pos_integer(), map()}} | {:error, Relay.Error.t()})) ::
          Plug.Conn.t()
  def idempotent(conn, work) do
    case work.() do
      {:ok, {status, body}} ->
        conn
        |> Plug.Conn.put_resp_header("idempotency-key", conn.assigns.idempotency_key)
        |> Response.json(status, body)

      {:error, %Relay.Error{} = error} ->
        Response.problem(conn, error)
    end
  end

  # API-56
  @doc "Reads the page parameters of a list request: `{:ok, limit, after_id}`."
  @spec page_params(Plug.Conn.t()) ::
          {:ok, pos_integer(), Relay.Id.t() | nil} | {:error, Relay.Error.t()}
  def page_params(conn) do
    %{scope: scope, operation: operation} = conn.assigns

    case Pagination.params(conn.query_params, scope, nil, operation.endpoint) do
      {:ok, %{limit: limit, cursor: nil}} -> {:ok, limit, nil}
      {:ok, %{limit: limit, cursor: %{id: id}}} -> {:ok, limit, id}
      {:error, error} -> {:error, error}
    end
  end

  # API-56
  @doc "Answers a page of rows fetched with `limit + 1`; the extra row only tells that more follow."
  @spec page(Plug.Conn.t(), [map()], pos_integer(), (map() -> map()), String.t()) :: Plug.Conn.t()
  def page(conn, rows, limit, render, id_key \\ "id") do
    %{scope: scope, operation: operation} = conn.assigns
    {items, more} = Enum.split(rows, limit)
    has_more = more != []

    next =
      with true <- has_more,
           %{^id_key => last} <- List.last(items),
           {:ok, cursor} <-
             Cursor.encode(scope, nil, operation.endpoint, %{sort_ts_us: 0, id: last}, :after) do
        cursor
      else
        _ -> nil
      end

    reply(conn, 200, Pagination.envelope(Enum.map(items, render), has_more, next))
  end

  @doc "Decodes a path identifier with its prefix; anything else is the operation's not found error."
  @spec path_id(String.t(), String.t(), atom()) :: {:ok, Relay.Id.t()} | {:error, Relay.Error.t()}
  def path_id(value, prefix, not_found) do
    case Relay.ExternalId.decode(value, [prefix]) do
      {:ok, id} -> {:ok, id}
      {:error, _} -> {:error, Relay.Error.new(not_found, "not found")}
    end
  end

  @doc "Decodes a body identifier with its prefix."
  @spec body_id(term(), String.t(), String.t()) :: {:ok, Relay.Id.t()} | {:error, Relay.Error.t()}
  def body_id(value, prefix, pointer) do
    case Relay.ExternalId.decode(value, [prefix]) do
      {:ok, id} -> {:ok, id}
      {:error, _} -> {:error, field(pointer, "invalid_format", "not a #{prefix}_ identifier")}
    end
  end

  # TN-48
  @doc "The audit actor of the request; `installation: true` for an installation operation."
  @spec actor(Plug.Conn.t(), keyword()) :: Relay.Actor.t()
  def actor(conn, opts \\ []) do
    refs = conn.assigns[:step_up_refs]

    opts =
      opts
      |> Keyword.put_new(:delegation, conn.assigns[:delegation_id])
      |> Keyword.put_new(:access_record_ref, refs && refs.step_up_ref)

    Operators.actor(conn.assigns.operator_session, opts)
  end

  # TN-21
  # TN-22
  @doc "Requires a step-up for a conditionally sensitive operation; returns the conn with `:step_up_refs`."
  @spec step_up(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:error, Relay.Error.t()}
  def step_up(%{assigns: %{step_up_refs: %{}}} = conn), do: {:ok, conn}

  def step_up(conn) do
    %{operator_session: session, operation: operation} = conn.assigns

    case Operators.step_up(session, operation.id, conn.request_path) do
      {:ok, refs} -> {:ok, Plug.Conn.assign(conn, :step_up_refs, refs)}
      {:error, error} -> {:error, error}
    end
  end

  @doc "The step-up reference of the request, or nil."
  @spec step_up_ref(Plug.Conn.t()) :: String.t() | nil
  def step_up_ref(conn) do
    case conn.assigns[:step_up_refs] do
      %{step_up_ref: ref} -> ref
      _ -> nil
    end
  end

  @doc "A `validation_failed` error naming one field."
  @spec field(String.t(), String.t(), String.t()) :: Relay.Error.t()
  def field(pointer, code, detail) do
    Relay.Error.new(:validation_failed, detail, %{
      errors: [%{pointer: pointer, code: code, detail: detail}]
    })
  end

  # API-8
  @doc "Reads an ISO 8601 duration of days, hours, minutes and seconds (`P1D`, `PT30M`, `P1DT2H`) as seconds."
  @spec duration(String.t()) :: {:ok, pos_integer()} | :error
  def duration(text) when is_binary(text) do
    case Regex.run(~r/\AP(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/, text) do
      [_ | parts] when text not in ["P", "PT"] ->
        seconds =
          parts
          |> Enum.zip([604_800, 86_400, 3_600, 60, 1])
          |> Enum.map(&part_seconds/1)
          |> Enum.sum()

        if seconds > 0, do: {:ok, seconds}, else: :error

      _ ->
        :error
    end
  end

  def duration(_text), do: :error

  defp part_seconds({"", _unit}), do: 0
  defp part_seconds({part, unit}), do: String.to_integer(part) * unit

  @doc "Reads an RFC 3339 time."
  @spec timestamp(term()) :: {:ok, DateTime.t()} | :error
  def timestamp(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _} -> :error
    end
  end

  def timestamp(_text), do: :error
end
