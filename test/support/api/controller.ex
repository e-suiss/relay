defmodule RelayTest.Api.Controller do
  @moduledoc "Operations of the edge test router: each runs through the real pipeline and answers with a contract-shaped body. The `x-test-work` header steers the idempotent work: `fail` fails without side effects, `partial` answers a stored 500, `business` answers a stored 422."

  use Phoenix.Controller, formats: [:json]

  use Boundary, top_level?: true, deps: [Relay, Relay.Api, RelayWeb], exports: []

  alias Relay.Api.Cursor
  alias Relay.Api.Pagination
  alias RelayWeb.Api.Response

  @runs :relay_test_api_runs

  @doc "How many times idempotent work ran in this process."
  @spec runs() :: non_neg_integer()
  def runs, do: Process.get(@runs, 0)

  @doc "Advances a pretend clock idempotently."
  @spec advance(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def advance(conn, _params) do
    work = Plug.Conn.get_req_header(conn, "x-test-work")

    Response.idempotent(conn, fn _status ->
      Process.put(@runs, runs() + 1)

      case work do
        ["fail"] ->
          {:error, Relay.Error.new(:internal_error, "failed before any side effect")}

        ["partial"] ->
          {:ok, Response.encode(conn, 500, %{"object" => "partial", "runs" => runs()})}

        _ ->
          {:ok, Response.encode(conn, 200, clock(runs()))}
      end
    end)
  end

  @doc "Reads the pretend clock."
  @spec clock(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def clock(conn, _params), do: Response.json(conn, 200, clock(runs()))

  @doc "Accepts a batch idempotently."
  @spec batch(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def batch(conn, _params) do
    Response.idempotent(conn, fn _status ->
      Process.put(@runs, runs() + 1)
      {:ok, Response.encode(conn, 202, %{"object" => "batch"})}
    end)
  end

  @doc "Lists nothing, with a next cursor."
  @spec list(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def list(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    case Pagination.params(conn.query_params, scope, nil, operation.endpoint) do
      {:ok, page} ->
        position = %{sort_ts_us: 1_700_000_000_000_000, id: Relay.Id.generate()}
        {:ok, next} = Cursor.encode(scope, nil, operation.endpoint, position, :after)
        Response.json(conn, 200, Pagination.envelope([], page.limit > 0, next))

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  defp clock(runs) do
    %{"object" => "virtual_clock", "offset_ms" => runs, "business_now" => "2026-11-01T00:00:00Z"}
  end
end
