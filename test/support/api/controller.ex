defmodule RelayTest.Api.Controller do
  @moduledoc "Operations of the edge test router: each runs through the real pipeline and answers with a contract-shaped body. The `x-test-work` header steers the idempotent work: `fail` fails without side effects, `partial` answers a stored 500, `business` answers a stored 422."

  use Phoenix.Controller, formats: [:json]

  use Boundary, top_level?: true, deps: [Relay, Relay.Api, RelayWeb], exports: []

  alias Relay.Api.Cursor
  alias Relay.Api.Pagination
  alias RelayWeb.Api.Response

  @runs :relay_test_api_runs
  @kill_switch "SELECT tenant_id, environment, id FROM relay.kill_switches WHERE id = $1"

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

  @doc "Finds a kill switch by identifier under the request's scope, as a resource endpoint does; any other tenant's or environment's record is not found."
  @spec kill_switch(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def kill_switch(conn, %{"kill_switch_id" => text}) do
    with {:ok, id} <- Relay.ExternalId.decode(text, ["ksw"]),
         {:ok, [_row]} <- kill_switch_rows(conn.assigns.scope, id) do
      Response.json(conn, 200, %{"object" => "kill_switch", "id" => text})
    else
      _ -> Response.problem(conn, Relay.Error.new(:kill_switch_not_found, "no such kill switch"))
    end
  end

  defp kill_switch_rows(scope, id) do
    Relay.Repo.in_scope(scope, fn _status ->
      Relay.Repo.scoped_query!(@kill_switch, [id], shared: :installation).rows
    end)
  end

  defp clock(runs) do
    %{"object" => "virtual_clock", "offset_ms" => runs, "business_now" => "2026-11-01T00:00:00Z"}
  end
end
