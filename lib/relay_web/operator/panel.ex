defmodule RelayWeb.Operator.Panel do
  @moduledoc """
  The job queue panel (Oban Web with oban_met) under `/v1/operator/queues`, for installation operators only (X-7, T-17, T-87, OP-40). The plug lets a request through only with a panel session of an installation operator and sends anyone else to the Access login. As the Oban Web resolver it shows the panel read-only, hides recorded job output and bounds every count and list query, so the panel's load on large job tables stays limited.
  """

  @behaviour Plug
  @behaviour Oban.Web.Resolver

  import Plug.Conn

  alias Relay.Operators
  alias Relay.Operators.Authz

  @login "/v1/operator/session/login?return_to=%2Fv1%2Foperator%2Fqueues"
  @jobs_limit 10_000
  @hint_limit 1_000

  @doc "The cookie session options of the panel and of its LiveView socket."
  @spec session_options() :: keyword()
  def session_options do
    [
      store: :cookie,
      key: "_relay_panel",
      signing_salt: "relay operator panel",
      encryption_salt: "relay operator panel encryption",
      same_site: "Strict",
      secure: true,
      http_only: true
    ]
  end

  @impl Plug
  def init(opts), do: opts

  # X-7
  # TN-23
  @impl Plug
  def call(conn, _opts) do
    case operator(conn) do
      nil -> conn |> put_resp_header("location", @login) |> send_resp(302, "") |> halt()
      _subject -> conn
    end
  end

  @impl Oban.Web.Resolver
  def resolve_user(conn), do: operator(conn)

  @impl Oban.Web.Resolver
  def resolve_access(nil), do: {:forbidden, @login}
  def resolve_access(_subject), do: :read_only

  @impl Oban.Web.Resolver
  def resolve_refresh(_subject), do: 5

  # OP-40
  @impl Oban.Web.Resolver
  def jobs_query_limit(_state), do: @jobs_limit

  @impl Oban.Web.Resolver
  def hint_query_limit(_qualifier), do: @hint_limit

  @impl Oban.Web.Resolver
  def cron_query_limit, do: @jobs_limit

  @impl Oban.Web.Resolver
  def format_recorded(_recorded, _job), do: "recorded output is not shown"

  defp operator(conn) do
    conn = fetch_cookies(conn)

    with token when is_binary(token) <- conn.req_cookies[RelayWeb.Operator.Pipeline.cookie()],
         {:ok, session} <- Operators.resolve(token),
         true <- Authz.installation_operator?(session.grants, Operators.installation_tenant_id()) do
      session.subject
    else
      _ -> nil
    end
  rescue
    _exception -> nil
  end
end
