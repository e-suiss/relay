defmodule Relay.CLITest do
  use ExUnit.Case, async: true

  alias Relay.CLI.ExitCode

  @api "https://relay.test"
  @issuer "https://access.test"
  @secret "s3cret-value"
  @now ~U[2026-11-01 09:00:00Z]

  defp env(extra \\ %{}) do
    Map.merge(
      %{
        "RELAY_API_URL" => @api,
        "RELAY_ACCESS_ISSUER" => @issuer,
        "RELAY_ENVIRONMENT" => "test",
        "RELAY_CLIENT_ID" => "cli_test",
        "RELAY_CLIENT_SECRET" => @secret
      },
      extra
    )
  end

  defp cli(argv, routes \\ %{}, opts \\ []) do
    {:ok, stdout} = StringIO.open("")
    {:ok, stderr} = StringIO.open("")
    {:ok, stdin} = StringIO.open(Keyword.get(opts, :input, ""))
    test = self()

    defaults = [
      env: env(),
      stdout: stdout,
      stderr: stderr,
      stdin: stdin,
      http: [plug: &respond(&1, routes)],
      sleep: fn ms -> send(test, {:slept, ms}) end,
      random_bytes: &:binary.copy(<<0>>, &1),
      now: fn -> @now end
    ]

    code = Relay.CLI.run(argv, Keyword.merge(defaults, Keyword.delete(opts, :input)))
    {_in, out} = StringIO.contents(stdout)
    {_in, err} = StringIO.contents(stderr)
    {code, out, err}
  end

  defp respond(conn, routes) do
    request = %{
      method: conn.method,
      host: conn.host,
      path: conn.request_path,
      query: conn.query_params,
      body: conn.body_params,
      headers: Map.new(conn.req_headers)
    }

    send(self(), {:request, request})

    key = {conn.method, conn.request_path}

    case Map.fetch(routes, key) do
      {:ok, responses} -> reply(conn, pick(conn, key, responses))
      :error -> fallback(conn)
    end
  end

  defp pick(conn, key, responses) when is_list(responses) do
    count = Process.get({:route, key}, 0)
    Process.put({:route, key}, count + 1)
    pick(conn, key, Enum.at(responses, count, List.last(responses)))
  end

  defp pick(conn, _key, fun) when is_function(fun, 1), do: fun.(conn)
  defp pick(_conn, _key, response), do: response

  defp fallback(%{method: "GET", request_path: "/.well-known/relay-configuration"} = conn),
    do: reply(conn, {200, %{"issuer" => @api, "access_client_id" => "app_relay"}})

  defp fallback(%{method: "GET", request_path: "/.well-known/openid-configuration"} = conn),
    do: reply(conn, {200, %{"issuer" => @issuer, "token_endpoint" => @issuer <> "/token"}})

  defp fallback(%{method: "POST", request_path: "/token"} = conn),
    do: reply(conn, {200, %{"access_token" => "opaque-token", "token_type" => "DPoP"}})

  defp fallback(conn), do: reply(conn, {418, %{"unexpected" => conn.request_path}})

  defp reply(conn, :transport_error), do: Req.Test.transport_error(conn, :timeout)
  defp reply(conn, {status, body}), do: reply(conn, {status, [], body})

  defp reply(conn, {status, headers, body}) do
    type =
      if is_map(body) and Map.has_key?(body, "code"),
        do: "application/problem+json",
        else: "application/json"

    conn
    |> Plug.Conn.merge_resp_headers(headers)
    |> Plug.Conn.put_resp_content_type(type)
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp problem(status, code, extra \\ %{}) do
    Map.merge(
      %{
        "type" => @api <> "/v1/errors/" <> code,
        "title" => code,
        "status" => status,
        "code" => code,
        "detail" => "detail of " <> code,
        "retryable" => false
      },
      extra
    )
  end

  defp jws(token) do
    [header, claims, _signature] = String.split(token, ".")
    decode = &(&1 |> Base.url_decode64!(padding: false) |> Jason.decode!())
    {decode.(header), decode.(claims)}
  end

  defp requests do
    receive do
      {:request, request} -> [request | requests()]
    after
      0 -> []
    end
  end

  defp api_requests,
    do: Enum.filter(requests(), &(&1.host == "relay.test" and &1.path =~ ~r/\A\/v1\//))

  defp client(conn) do
    ["Basic " <> basic] = Plug.Conn.get_req_header(conn, "authorization")

    case Base.decode64!(basic) do
      "cli_test:" <> _secret -> "test-token"
      "cli_live:" <> _secret -> "live-token"
    end
  end

  defp kill_switch(id), do: %{"id" => id, "status" => "active", "scope_kind" => "workflow"}

  defp list(data, more \\ nil),
    do: %{"object" => "list", "data" => data, "has_more" => more != nil, "next_cursor" => more}

  defp notification(id, at) do
    %{
      "object" => "notification",
      "id" => id,
      "workflow" => %{"key" => "welcome", "version" => 1},
      "external_id" => "user-1",
      "state" => "active",
      "delivery_counts" => %{"delivered" => 1},
      "created_at" => at
    }
  end

  describe "exit codes" do
    test "X-42: an unknown command or option is a usage error with exit code 2" do
      assert {2, "", err} = cli(["frobnicate"])
      assert err =~ "unknown command frobnicate"

      assert {2, out, ""} = cli(["logs", "--bogus", "--json"])
      assert %{"exit_code" => 2, "error" => %{"code" => "usage_error"}} = Jason.decode!(out)

      assert {2, _out, err} = cli(["trigger"])
      assert err =~ "takes exactly one argument"
    end

    test "X-42: help prints the usage and exits 0" do
      assert {0, out, ""} = cli(["help"])
      assert out =~ "Usage: relay"
      assert {0, ^out, ""} = cli(["logs", "--help"])
    end

    test "X-42: each HTTP status maps to its stable exit code, with the problem in JSON" do
      table = [
        {400, 5},
        {401, 3},
        {403, 3},
        {404, 4},
        {409, 5},
        {412, 5},
        {413, 5},
        {422, 5},
        {428, 5},
        {429, 6},
        {500, 7},
        {503, 7}
      ]

      for {status, code} <- table do
        routes = %{
          {"GET", "/v1/kill_switches/ksw_1"} => {status, problem(status, "code_#{status}")}
        }

        {exit_code, out, _err} = cli(["kill-switch", "get", "ksw_1", "--json"], routes)

        assert exit_code == code
        assert ExitCode.code(ExitCode.for_status(status)) == code

        assert %{"exit_code" => ^code, "error" => error} = Jason.decode!(out)
        assert %{"code" => "code_" <> _status, "status" => ^status, "problem" => _problem} = error
      end
    end

    test "X-42: a connection failure is exit code 7 and success carries exit_code 0" do
      routes = %{{"GET", "/v1/kill_switches"} => :transport_error}
      assert {7, "", err} = cli(["kill-switch", "list"], routes)
      assert err =~ "connection_failed"

      routes = %{{"GET", "/v1/kill_switches"} => {200, list([kill_switch("ksw_1")])}}
      assert {0, out, ""} = cli(["kill-switch", "list", "--json"], routes)

      assert %{"exit_code" => 0, "result" => %{"kill_switches" => [%{"id" => "ksw_1"}]}} =
               Jason.decode!(out)
    end
  end

  describe "access" do
    test "X-33, E-78, E-93: the token endpoint and Relay's client_id are discovered; one token serves the whole run" do
      routes = %{
        {"GET", "/v1/kill_switches"} => [
          {200, list([kill_switch("ksw_1")], "cur_2")},
          {200, list([kill_switch("ksw_2")])}
        ]
      }

      assert {0, out, ""} = cli(["kill-switch", "list"], routes)
      assert out =~ "ksw_1" and out =~ "ksw_2"

      [relay, discovery, token, first, second] = requests()
      assert relay.path == "/.well-known/relay-configuration"
      assert discovery.path == "/.well-known/openid-configuration"
      assert token.body == %{"grant_type" => "client_credentials", "resource" => "app_relay"}
      assert token.headers["authorization"] == "Basic " <> Base.encode64("cli_test:" <> @secret)
      assert first.headers["authorization"] == "DPoP opaque-token"
      assert second.headers["authorization"] == "DPoP opaque-token"
      assert second.query["starting_after"] == "cur_2"

      {header, claims} = jws(token.headers["dpop"])
      assert %{"typ" => "dpop+jwt", "alg" => "Ed25519", "jwk" => %{"kty" => "OKP"}} = header
      assert %{"htm" => "POST", "htu" => @issuer <> "/token"} = claims
      refute Map.has_key?(claims, "ath")

      {^header, claims} = jws(first.headers["dpop"])
      ath = Base.url_encode64(:crypto.hash(:sha256, "opaque-token"), padding: false)
      assert %{"htm" => "GET", "htu" => @api <> "/v1/kill_switches", "ath" => ^ath} = claims
    end

    test "E-93: a use_dpop_nonce answer is sent again once with the nonce" do
      nonce = [{"dpop-nonce", "n-1"}]
      ask = {400, nonce, %{"error" => "use_dpop_nonce"}}
      issued = {200, %{"access_token" => "opaque-token", "token_type" => "DPoP"}}

      routes = %{
        {"POST", "/token"} => [ask, issued],
        {"GET", "/v1/kill_switches"} => {200, list([])}
      }

      assert {0, _out, ""} = cli(["kill-switch", "list"], routes)
      [first, second] = Enum.filter(requests(), &(&1.path == "/token"))
      refute Map.has_key?(elem(jws(first.headers["dpop"]), 1), "nonce")
      assert elem(jws(second.headers["dpop"]), 1)["nonce"] == "n-1"
    end

    test "E-93: a token that is not DPoP-bound is refused before any API call" do
      routes = %{{"POST", "/token"} => {200, %{"access_token" => "t", "token_type" => "Bearer"}}}

      assert {3, out, ""} = cli(["kill-switch", "list", "--json"], routes)

      assert %{"exit_code" => 3, "error" => %{"code" => "access_token_refused"}} =
               Jason.decode!(out)

      assert api_requests() == []
    end

    test "X-33: the environment of the API client must be chosen" do
      env = Map.delete(env(), "RELAY_ENVIRONMENT")
      assert {2, "", err} = cli(["kill-switch", "list"], %{}, env: env)
      assert err =~ "--env test|live"
      assert requests() == []
    end

    test "X-33: the client secret never appears in the output" do
      body = %{"error" => "invalid_client", "error_description" => "unknown client"}
      routes = %{{"POST", "/token"} => {401, body}}

      for argv <- [["kill-switch", "list"], ["kill-switch", "list", "--json"]] do
        {code, out, err} = cli(argv, routes)
        assert code == 3
        assert out <> err =~ "access_invalid_client"
        refute out <> err =~ @secret
      end
    end

    @tag :tmp_dir
    test "X-33: a profile file names the API, the issuer and the client of each environment",
         %{tmp_dir: dir} do
      secret = Path.join(dir, "test.secret")
      File.write!(secret, "from-file\n")

      profile = %{
        "api_url" => @api,
        "access_issuer" => @issuer,
        "environment" => "test",
        "test" => %{"client_id" => "cli_profile", "client_secret_file" => secret}
      }

      config = Path.join(dir, "config.json")
      File.write!(config, Jason.encode!(%{"profiles" => %{"dev" => profile}}))

      routes = %{{"GET", "/v1/kill_switches"} => {200, list([])}}
      env = %{"RELAY_CONFIG" => config, "RELAY_PROFILE" => "dev"}
      assert {0, _out, ""} = cli(["kill-switch", "list"], routes, env: env)

      token = Enum.find(requests(), &(&1.path == "/token"))
      assert token.headers["authorization"] == "Basic " <> Base.encode64("cli_profile:from-file")
    end
  end

  describe "retries" do
    test "X-33, API-65: a retried mutating call keeps its Idempotency-Key" do
      accepted = %{"object" => "event", "id" => "evt_1", "notifications" => []}

      routes = %{
        {"POST", "/v1/events"} => [
          {429, [{"retry-after", "2"}], problem(429, "rate_limited", %{"retryable" => true})},
          {202, accepted}
        ]
      }

      assert {0, out, ""} = cli(["trigger", "welcome", "--to", "user-1"], routes)
      assert out =~ "accepted event evt_1"
      assert_received {:slept, 2000}

      [first, second] = Enum.filter(api_requests(), &(&1.path == "/v1/events"))
      assert "relay-cli-" <> _random = first.headers["idempotency-key"]
      assert first.headers["idempotency-key"] == second.headers["idempotency-key"]
    end

    test "X-33, API-65: a problem that is not retryable is reported at once" do
      routes = %{{"POST", "/v1/events"} => {422, problem(422, "validation_failed")}}

      assert {5, "", err} = cli(["trigger", "welcome", "--to", "user-1"], routes)
      assert err =~ "validation_failed: detail of validation_failed"
      assert length(api_requests()) == 1
      refute_received {:slept, _ms}
    end
  end

  describe "trigger and preview" do
    test "X-33, L-30: trigger sends one event to the workflow with its recipients and data" do
      accepted = %{
        "object" => "event",
        "id" => "evt_1",
        "notifications" => [%{"notification_id" => "ntf_1", "external_id" => "user-1"}]
      }

      routes = %{{"POST", "/v1/events"} => {202, accepted}}

      argv = [
        "trigger",
        "welcome",
        "--to",
        "user-1",
        "--recipient",
        ~s({"id": "user-2", "email": "ayse@example.com"}),
        "--data",
        ~s({"first_name": "Ayşe"})
      ]

      assert {0, out, ""} = cli(argv, routes)
      assert out =~ "ntf_1 -> user-1"

      [event] = api_requests()

      assert event.body == %{
               "workflow" => "welcome",
               "to" => ["user-1", %{"id" => "user-2", "email" => "ayse@example.com"}],
               "data" => %{"first_name" => "Ayşe"}
             }
    end

    test "X-33: a live change without confirmation exits 8 and sends nothing" do
      live = env(%{"RELAY_ENVIRONMENT" => "live"})
      argv = ["trigger", "welcome", "--to", "user-1"]

      assert {8, "", err} = cli(argv, %{}, env: live)
      assert err =~ "--yes"
      assert requests() == []

      assert {8, "", _err} = cli(argv, %{}, env: live, interactive?: true, input: "n\n")
      assert requests() == []
    end

    test "X-33: a live change goes ahead with --yes or a confirmed prompt" do
      live = env(%{"RELAY_ENVIRONMENT" => "live"})
      routes = %{{"POST", "/v1/events"} => {202, %{"id" => "evt_1", "notifications" => []}}}
      argv = ["trigger", "welcome", "--to", "user-1"]

      assert {0, _out, ""} = cli(argv ++ ["--yes"], routes, env: live)
      assert {0, _out, err} = cli(argv, routes, env: live, interactive?: true, input: "y\n")
      assert err =~ "Continue? [y/N]"
      assert Enum.count(api_requests(), &(&1.path == "/v1/events")) == 2
    end

    test "X-33, API-62: preview runs a dry run with local data and refuses a live client" do
      routes = %{{"POST", "/v1/events"} => {202, %{"id" => "evt_1", "notifications" => []}}}
      argv = ["preview", "welcome", "--to", "user-1", "--data", ~s({"n": 1})]

      assert {0, out, ""} = cli(argv, routes)
      assert out =~ "dry run of event evt_1"
      assert [%{body: %{"send_mode" => "dry_run", "data" => %{"n" => 1}}}] = api_requests()

      live = env(%{"RELAY_ENVIRONMENT" => "live"})
      assert {3, "", err} = cli(argv, routes, env: live)
      assert err =~ "preview_requires_test"
      assert requests() == []
    end

    test "X-33, API-60: preview --template renders a template with local data and prints SMS numbers" do
      render = %{
        "channel" => "sms",
        "locale" => "tr",
        "content" => %{"body" => "Çağrı A-1"},
        "failure_reason" => nil,
        "warnings" => [%{"code" => "sms_ucs2_characters", "message" => "UCS-2"}],
        "sms" => %{
          "encoding" => "GSM7_TR",
          "encoding_unverified_provider" => "UCS2",
          "segments" => 1,
          "characters" => 9
        }
      }

      preview = %{
        "object" => "template_preview",
        "template_key" => "order-shipped",
        "version" => "draft",
        "sample" => "data",
        "renders" => [render]
      }

      routes = %{{"POST", "/v1/templates/order-shipped/preview"} => {200, preview}}

      argv = [
        "preview",
        "order-flow",
        "--template",
        "order-shipped",
        "--channel",
        "sms",
        "--version",
        "2",
        "--data",
        ~s({"order": "A-1"})
      ]

      live = env(%{"RELAY_ENVIRONMENT" => "live"})
      assert {0, out, ""} = cli(argv, routes, env: live)
      assert out =~ "preview of order-shipped (draft, data)"
      assert out =~ "SMS GSM7_TR, 1 segment(s), 9 character(s); unverified provider: UCS2"
      assert out =~ "warning: sms_ucs2_characters"

      assert [%{body: body}] = api_requests()

      assert body == %{
               "workflow" => "order-flow",
               "channels" => ["sms"],
               "version" => 2,
               "data" => %{"order" => "A-1"}
             }

      assert {2, _out, err} = cli(argv ++ ["--sample", "other"], routes)
      assert err =~ "--sample"
    end

    test "X-33, API-60: preview --steps shows each step's decision" do
      steps = %{
        "object" => "workflow_preview",
        "workflow_key" => "order-flow",
        "version" => "live",
        "sample" => "boundary",
        "steps" => [
          %{
            "step" => "email_step",
            "channel" => "email",
            "template" => "order-shipped",
            "would_send" => false,
            "reason" => "template",
            "rule_id" => "template.variant_missing",
            "render" => nil
          }
        ]
      }

      routes = %{{"POST", "/v1/workflows/order-flow/preview"} => {200, steps}}
      assert {0, out, ""} = cli(["preview", "order-flow", "--steps"], routes)
      assert out =~ "email_step email order-shipped: skipped template.variant_missing"
      assert [%{body: %{}}] = api_requests()
    end
  end

  describe "kill switches" do
    test "X-33: engage sends the contract body; release needs an operator session" do
      engaged = Map.put(kill_switch("ksw_1"), "state", "off")

      routes = %{
        {"POST", "/v1/kill_switches"} => {201, engaged},
        {"POST", "/v1/kill_switches/ksw_1/release"} =>
          {403, problem(403, "auth_operator_session_required")}
      }

      argv = ~w(kill-switch engage --scope workflow --ref welcome --reason broken --ttl PT1H)
      assert {0, out, ""} = cli(argv, routes)
      assert out =~ "ksw_1 active workflow state=off"

      assert [%{body: body}] = api_requests()

      assert body == %{
               "scope_kind" => "workflow",
               "scope_ref" => "welcome",
               "reason" => "broken",
               "ttl" => "PT1H"
             }

      assert {3, "", err} = cli(~w(kill-switch release ksw_1 --reason fixed), routes)
      assert err =~ "auth_operator_session_required"

      assert {2, "", err} = cli(~w(kill-switch engage --scope workflow --reason broken), routes)
      assert err =~ "--ttl is required"
    end
  end

  describe "workflow files" do
    @tag :tmp_dir
    test "X-33: pull writes each workflow to a file and push writes it back as a draft",
         %{tmp_dir: dir} do
      draft = %{"name" => "Welcome", "steps" => []}
      workflow = %{"object" => "workflow", "key" => "welcome", "draft" => draft}

      routes = %{
        {"GET", "/v1/workflows"} => {200, list([workflow])},
        {"GET", "/v1/workflows/welcome"} => {200, [{"etag", ~s("3")}], workflow}
      }

      assert {0, out, ""} = cli(["pull", "--dir", dir], routes)
      assert out =~ "pulled welcome (draft)"
      path = Path.join(dir, "welcome.json")
      assert %{"key" => "welcome", "definition" => ^draft} = Jason.decode!(File.read!(path))

      changed = %{draft | "name" => "Welcome!"}
      File.write!(path, Jason.encode!(%{"key" => "welcome", "definition" => changed}))

      routes =
        Map.merge(routes, %{
          {"PUT", "/v1/workflows/welcome"} => {200, [{"etag", ~s("4")}], workflow},
          {"POST", "/v1/workflows/welcome/publish"} =>
            {202, %{"workflow_key" => "welcome", "publication" => %{"status" => "pending"}}}
        })

      requests()
      assert {0, out, ""} = cli(["push", "--dir", dir, "--publish"], routes)
      assert out =~ "welcome: draft updated, publication pending"

      [_get, put, publish] = api_requests()
      assert put.method == "PUT"
      assert put.headers["if-match"] == ~s("3")
      assert put.body == %{"definition" => changed}
      assert publish.headers["if-match"] == ~s("4")
      assert put.headers["idempotency-key"] != nil
    end

    @tag :tmp_dir
    test "X-33: push creates a workflow that does not exist yet", %{tmp_dir: dir} do
      definition = %{"name" => "Welcome", "steps" => []}
      content = Jason.encode!(%{"key" => "welcome", "definition" => definition})
      File.write!(Path.join(dir, "welcome.json"), content)

      routes = %{
        {"GET", "/v1/workflows/welcome"} => {404, problem(404, "workflow_not_found")},
        {"POST", "/v1/workflows"} => {201, [{"etag", ~s("1")}], %{"key" => "welcome"}}
      }

      assert {0, out, ""} = cli(["push", "--dir", dir], routes)
      assert out =~ "welcome: draft created"
      assert [_get, create] = api_requests()
      assert create.body == %{"key" => "welcome", "definition" => definition}

      File.write!(Path.join(dir, "broken.json"), ~s({"key": "broken"}))
      assert {5, "", err} = cli(["push", Path.join(dir, "broken.json")], routes)
      assert err =~ "invalid_workflow_file"
    end

    test "X-33: promote publishes the test version of a workflow in live" do
      definition = %{"name" => "Welcome", "steps" => []}

      by_client = fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["DPoP test-token"] -> {200, %{"key" => "welcome", "published_version" => 2}}
          ["DPoP live-token"] -> {404, problem(404, "workflow_not_found")}
        end
      end

      issue = fn conn -> {200, %{"access_token" => client(conn), "token_type" => "DPoP"}} end

      routes = %{
        {"POST", "/token"} => issue,
        {"GET", "/v1/workflows/welcome"} => by_client,
        {"GET", "/v1/workflows/welcome/versions/2"} =>
          {200, %{"version" => 2, "definition" => definition}},
        {"POST", "/v1/workflows"} => {201, [{"etag", ~s("1")}], %{"key" => "welcome"}},
        {"POST", "/v1/workflows/welcome/publish"} =>
          {202, %{"publication" => %{"status" => "pending"}}}
      }

      env =
        env(%{
          "RELAY_TEST_CLIENT_ID" => "cli_test",
          "RELAY_TEST_CLIENT_SECRET" => "test-secret",
          "RELAY_LIVE_CLIENT_ID" => "cli_live",
          "RELAY_LIVE_CLIENT_SECRET" => "live-secret"
        })

      assert {8, "", _err} = cli(["promote", "welcome"], routes, env: env)
      assert api_requests() == []

      assert {0, out, ""} = cli(["promote", "welcome", "--yes"], routes, env: env)
      assert out =~ "promoted welcome test version 2 to live: publication pending"

      calls =
        for request <- api_requests(),
            do: {request.method, request.path, request.headers["authorization"]}

      assert calls == [
               {"GET", "/v1/workflows/welcome", "DPoP test-token"},
               {"GET", "/v1/workflows/welcome/versions/2", "DPoP test-token"},
               {"GET", "/v1/workflows/welcome", "DPoP live-token"},
               {"POST", "/v1/workflows", "DPoP live-token"},
               {"POST", "/v1/workflows/welcome/publish", "DPoP live-token"}
             ]
    end
  end

  describe "logs and listen" do
    test "X-33: logs prints the newest notifications and --follow prints each new one once" do
      first = notification("ntf_1", "2026-11-01T08:59:00Z")
      second = notification("ntf_2", "2026-11-01T09:00:05Z")
      third = notification("ntf_3", "2026-11-01T09:00:09Z")

      routes = %{
        {"GET", "/v1/notifications"} => [
          {200, list([first])},
          {200, list([second])},
          {200, list([second, third])}
        ]
      }

      argv = ["logs", "--follow", "--interval", "1", "--json"]
      assert {0, out, ""} = cli(argv, routes, max_polls: 2)

      lines = out |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      ids = for %{"type" => "notification", "data" => %{"id" => id}} <- lines, do: id
      assert ids == ["ntf_1", "ntf_2", "ntf_3"]
      assert %{"exit_code" => 0, "result" => %{"polls" => 2}} = List.last(lines)

      [_page, poll, next] = api_requests()
      assert poll.query["created_after"] == "2026-11-01T09:00:00Z"
      assert next.query["created_after"] == "2026-11-01T09:00:05Z"
      assert_received {:slept, 1000}
    end

    test "API-64: listen forwards new notifications to a local address, never the token" do
      fresh = notification("ntf_2", "2026-11-01T09:00:05Z")

      routes = %{
        {"GET", "/v1/notifications"} => {200, list([fresh])},
        {"POST", "/hook"} => {200, %{"ok" => true}}
      }

      argv = ["listen", "--forward-to", "http://localhost:4000/hook"]
      assert {0, out, err} = cli(argv, routes, max_polls: 1)
      assert out =~ "ntf_2 -> 200"
      assert err =~ "forwarding new notifications"

      [forward] = Enum.filter(requests(), &(&1.host == "localhost"))
      assert forward.body == fresh
      refute Map.has_key?(forward.headers, "authorization")

      argv = ["listen", "--forward-to", "https://hooks.example.com/relay"]
      assert {2, "", err} = cli(argv, routes, max_polls: 1)
      assert err =~ "local address"
      assert requests() == []
    end
  end
end
