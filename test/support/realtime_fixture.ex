defmodule RelayTest.RealtimeFixture do
  @moduledoc "A tenant linked to the fake Access and subscriber tokens from the real token exchange, for realtime tests; the test needs the database."

  use Boundary,
    top_level?: true,
    deps: [Relay, RelayWeb, RelayTest.Api, RelayTest.FakeAccess, RelayTest.TenantFixture],
    exports: []

  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.TenantFixture

  @grant "urn:ietf:params:oauth:grant-type:token-exchange"
  @subject_type "urn:ietf:params:oauth:token-type:access_token"

  @doc "Links the fake Access and registers an Access client in a new tenant's `test` environment."
  @spec setup!() :: map()
  def setup! do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    app = FakeAccess.client!(tenant.test, ["read"])
    %{scope: tenant.test, access_tenant: tenant.attrs.access_tenant_id, app: app}
  end

  @doc "A pairwise subject for a new subscriber."
  @spec subject() :: String.t()
  def subject, do: "pairwise-" <> FakeAccess.random()

  @doc "Exchanges an end user's Access token for a subscriber token with `scope` (the default scopes when `nil`) and returns the token and the subscriber."
  @spec token!(map(), String.t(), String.t() | nil) :: {String.t(), Relay.Id.t()}
  def token!(ctx, sub, scope \\ nil) do
    access_token = FakeAccess.user_token(ctx.access_tenant, ctx.app, sub)

    form = %{
      "grant_type" => @grant,
      "subject_token" => access_token,
      "subject_token_type" => @subject_type
    }

    form = if scope, do: Map.put(form, "scope", scope), else: form

    conn =
      :post
      |> Api.conn(
        "/v1/subscriber/token",
        URI.encode_query(form),
        FakeAccess.exchange_headers(access_token)
      )
      |> Api.call(RelayWeb.Router)

    200 = conn.status
    body = Jason.decode!(conn.resp_body)
    {:ok, id} = Relay.ExternalId.decode(body["subscriber_id"], ["sub"])
    {body["access_token"], id}
  end
end
