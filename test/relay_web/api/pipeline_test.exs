defmodule RelayWeb.Api.PipelineTest do
  use Relay.DataCase, async: true

  import Plug.Conn

  alias Relay.Api.Store
  alias Relay.Api.Tenant
  alias Relay.Api.Versions
  alias RelayTest.Api
  alias RelayTest.Api.Controller
  alias RelayTest.Api.Verifier
  alias RelayTest.TenantFixture

  setup do
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, token: Api.token(tenant.test, ["config"])}
  end

  defp advance(token, body \\ %{"by" => "PT1H"}, headers \\ []) do
    :post
    |> Api.json("/v1/virtual_clock/advance", token, body, headers)
    |> Api.call()
  end

  defp key(value \\ "key-" <> Base.encode16(:crypto.strong_rand_bytes(6))),
    do: {"idempotency-key", value}

  defp problem(conn, status) do
    assert conn.status == status
    assert ["application/problem+json" <> _] = get_resp_header(conn, "content-type")
    Api.assert_contract(conn)
    Jason.decode!(conn.resp_body)
  end

  describe "API-8 common rules" do
    test "API-8: every response carries Request-Id, Relay-Version and HSTS", ctx do
      conn = advance(ctx.token, %{"by" => "PT1H"}, [key()])

      assert conn.status == 200
      assert [_] = get_resp_header(conn, "request-id")
      assert get_resp_header(conn, "relay-version") == [Versions.latest()]
      assert ["max-age=" <> _] = get_resp_header(conn, "strict-transport-security")
      assert ["application/json; charset=utf-8"] = get_resp_header(conn, "content-type")
      Api.assert_contract(conn)
    end

    test "API-8: plain HTTP is refused", ctx do
      conn =
        :post
        |> Api.json("/v1/virtual_clock/advance", ctx.token, %{"by" => "PT1H"}, [key()])
        |> Map.put(:scheme, :http)
        |> Api.call()

      assert problem(conn, 400)["code"] == "malformed_request"
    end

    test "API-8: a body that is not JSON in UTF-8 is 415", ctx do
      for type <- ["text/plain", "application/json; charset=latin1", "application/xml"] do
        conn =
          :post
          |> Api.conn("/v1/virtual_clock/advance", ~s({"by":"PT1H"}), [
            {"content-type", type},
            {"authorization", "Bearer " <> ctx.token},
            key()
          ])
          |> Api.call()

        assert problem(conn, 415)["code"] == "unsupported_media_type"
      end
    end

    test "API-8: malformed JSON is 400 and an oversized body is 413", ctx do
      assert problem(advance(ctx.token, "{not json", [key()]), 400)["code"] == "malformed_request"

      conn = advance(ctx.token, %{"by" => "PT1H"}, [key(), {"content-length", "2000000"}])
      body = problem(conn, 413)
      assert body["code"] == "payload_too_large"
      assert body["limit"] == 1_048_576
    end

    test "API-8: an unknown field is 422 unknown_field with every field error", ctx do
      body = problem(advance(ctx.token, %{"by" => "PT1H", "speed" => 2}, [key()]), 422)

      assert body["code"] == "unknown_field"
      assert %{"pointer" => "/speed", "code" => "not_allowed"} in body["errors"]
      assert Controller.runs() == 0
    end
  end

  describe "API-43 and API-47 authentication" do
    test "API-47: a missing or malformed credential is 401 with a Bearer challenge" do
      missing = advance(nil, %{"by" => "PT1H"}, [key()])
      assert problem(missing, 401)["code"] == "auth_missing_credentials"
      assert [~s(Bearer realm="relay")] = get_resp_header(missing, "www-authenticate")

      malformed = advance(nil, %{"by" => "PT1H"}, [key(), {"authorization", "Basic abc"}])
      assert problem(malformed, 401)["code"] == "auth_malformed_credentials"
    end

    test "API-47: an invalid or expired token is 401 with error=invalid_token" do
      for code <- [:auth_invalid_token, :auth_expired_token] do
        conn = advance(Verifier.failing(code), %{"by" => "PT1H"}, [key()])
        assert problem(conn, 401)["code"] == Atom.to_string(code)
        assert [challenge] = get_resp_header(conn, "www-authenticate")
        assert challenge =~ ~s(error="invalid_token")
      end
    end

    test "API-47: invalid tokens are limited per client IP; past 20 the answer is 429" do
      ip = Api.ip()
      token = Verifier.failing(:auth_invalid_token)

      statuses =
        for _ <- 1..21 do
          :post
          |> Api.json("/v1/virtual_clock/advance", token, %{"by" => "PT1H"}, [key()])
          |> Map.put(:remote_ip, ip)
          |> Api.call()
          |> Map.fetch!(:status)
        end

      assert Enum.take(statuses, 20) == List.duplicate(401, 20)
      assert List.last(statuses) == 429
    end

    test "API-43: a missing scope is 403 with required_scope and granted_scopes", ctx do
      token = Api.token(ctx.tenant.test, ["read"])
      body = problem(advance(token, %{"by" => "PT1H"}, [key()]), 403)

      assert body["code"] == "auth_insufficient_scope"
      assert body["required_scope"] == "config"
      assert body["granted_scopes"] == ["read"]
    end

    test "API-76 (2): a live client calling a test-only operation is auth_environment_mismatch",
         ctx do
      token = Api.token(ctx.tenant.live, ["config"])
      assert problem(advance(token, %{"by" => "PT1H"}, [key()]), 403)["code"] ==
               "auth_environment_mismatch"
    end

    test "API-47: operator session headers with an API client token are 422", ctx do
      conn = advance(ctx.token, %{"by" => "PT1H"}, [key(), {"relay-environment", "live"}])
      assert problem(conn, 422)["code"] == "validation_failed"
    end

    test "TN-10: a suspended tenant gets auth_tenant_suspended", ctx do
      {:ok, row} = Relay.Tenancy.tenant(ctx.tenant.live)

      {:ok, {:changed, _}} =
        Relay.Tenancy.set_tenant_status(
          ctx.tenant.live,
          %{
            status: :suspended,
            reason: "test",
            expected_version: row["version"],
            record_digest: TenantFixture.digest()
          },
          TenantFixture.actor()
        )

      assert problem(advance(ctx.token, %{"by" => "PT1H"}, [key()]), 403)["code"] ==
               "auth_tenant_suspended"
    end
  end

  describe "API-10 … API-15 idempotency at the edge" do
    test "API-10: a mutating request without a key is 400; a bad key is idempotency_key_invalid",
         ctx do
      assert problem(advance(ctx.token), 400)["code"] == "idempotency_key_missing"
      assert problem(advance(ctx.token, %{"by" => "PT1H"}, [key("short")]), 400)["code"] ==
               "idempotency_key_invalid"

      assert Controller.runs() == 0
    end

    test "API-13: the same key and body replays the first response byte for byte", ctx do
      header = key()
      first = advance(ctx.token, %{"by" => "PT1H"}, [header])
      second = advance(ctx.token, %{"by" => "PT1H"}, [header])

      assert first.status == 200
      assert second.status == 200
      assert second.resp_body == first.resp_body
      assert get_resp_header(second, "idempotency-replayed") == ["true"]
      assert get_resp_header(first, "idempotency-replayed") == []
      assert Controller.runs() == 1
    end

    test "API-11: a quoted key is the same key", ctx do
      first = advance(ctx.token, %{"by" => "PT1H"}, [key("quoted-key-1")])
      second = advance(ctx.token, %{"by" => "PT1H"}, [key(~s("quoted-key-1"))])

      assert second.resp_body == first.resp_body
      assert get_resp_header(second, "idempotency-replayed") == ["true"]
    end

    test "API-13: the same key with another body is idempotency_key_reuse", ctx do
      header = key()
      assert advance(ctx.token, %{"by" => "PT1H"}, [header]).status == 200
      assert problem(advance(ctx.token, %{"by" => "PT2H"}, [header]), 422)["code"] ==
               "idempotency_key_reuse"
    end

    test "API-11: the scope includes the endpoint", ctx do
      header = key()
      assert advance(ctx.token, %{"by" => "PT1H"}, [header]).status == 200

      publish = Api.token(ctx.tenant.test, ["publish"])

      batch =
        :post
        |> Api.json("/v1/events/batch", publish, batch(1), [header])
        |> Api.call()

      assert batch.status == 202
      assert get_resp_header(batch, "idempotency-replayed") == []
      assert Controller.runs() == 2
    end

    test "API-14: a failure without side effects is not stored and the retry runs", ctx do
      header = key()
      failed = advance(ctx.token, %{"by" => "PT1H"}, [header, {"x-test-work", "fail"}])

      body = problem(failed, 500)
      assert body["code"] == "internal_error"
      assert body["retryable"] == true
      assert get_resp_header(failed, "retry-after") == ["2"]

      assert advance(ctx.token, %{"by" => "PT1H"}, [header]).status == 200
      assert Controller.runs() == 2
    end

    test "API-14: a 5xx after partial execution is stored and replayed", ctx do
      header = key()
      first = advance(ctx.token, %{"by" => "PT1H"}, [header, {"x-test-work", "partial"}])
      second = advance(ctx.token, %{"by" => "PT1H"}, [header])

      assert first.status == 500
      assert second.status == 500
      assert second.resp_body == first.resp_body
      assert Controller.runs() == 1
    end

    test "API-14: 401, 403 and 429 answers are never stored", ctx do
      header = key()
      read = Api.token(ctx.tenant.test, ["read"])
      assert advance(read, %{"by" => "PT1H"}, [header]).status == 403
      assert advance(ctx.token, %{"by" => "PT1H"}, [header]).status == 200
      assert Controller.runs() == 1
    end

    test "API-10: a read ignores the Idempotency-Key header", ctx do
      conn =
        :get
        |> Api.conn("/v1/virtual_clock", nil, [
          {"authorization", "Bearer " <> Api.token(ctx.tenant.test, ["read"])},
          {"idempotency-key", "x"}
        ])
        |> Api.call()

      assert conn.status == 200
      Api.assert_contract(conn)
    end
  end

  describe "API-52 … API-55 versions" do
    test "API-52: an unsupported Relay-Version is 400 with the supported list", ctx do
      conn = advance(ctx.token, %{"by" => "PT1H"}, [key(), {"relay-version", "2019-01-01"}])
      body = problem(conn, 400)

      assert body["code"] == "unsupported_api_version"
      assert body["supported_versions"] == Versions.supported()
    end

    test "API-52: the first successful request pins the latest version; later ones are served it",
         ctx do
      assert {:ok, %{api_version: nil}} = Tenant.edge(ctx.tenant.test)
      assert problem(advance(ctx.token, %{"by" => "PT1H", "x" => 1}, [key()]), 422)
      assert {:ok, %{api_version: nil}} = Tenant.edge(ctx.tenant.test)

      assert advance(ctx.token, %{"by" => "PT1H"}, [key()]).status == 200
      latest = Versions.latest()
      assert {:ok, %{api_version: ^latest}} = Tenant.edge(ctx.tenant.test)
      assert {:ok, %{api_version: ^latest}} = Tenant.edge(ctx.tenant.live)

      conn = advance(ctx.token, %{"by" => "PT1H"}, [key()])
      assert get_resp_header(conn, "relay-version") == [latest]
    end

    test "API-52: the automatic pin is written once; a manual change is its own mode", ctx do
      {:ok, actor} = Relay.Actor.new(:api_client, "cli_test", "cli_test")
      latest = Versions.latest()

      assert {:ok, :pinned} = Tenant.pin(ctx.tenant.test, latest, actor)
      assert {:ok, :already_pinned} = Tenant.pin(ctx.tenant.live, latest, actor)
      assert {:ok, :unsupported} = Tenant.pin(ctx.tenant.live, "2020-01-01", actor)

      manual = fn version ->
        Store.in_scope(ctx.tenant.live, fn _status ->
          Store.api_version_pin(version, false, TenantFixture.digest(), actor)
        end)
      end

      assert {:ok, :unchanged} = manual.(latest)
      assert {:ok, :changed} = manual.("2027-01-01")
      assert {:ok, %{api_version: "2027-01-01"}} = Tenant.edge(ctx.tenant.test)
    end

    test "API-55: an unknown Relay-Beta feature is 400", ctx do
      conn = advance(ctx.token, %{"by" => "PT1H"}, [key(), {"relay-beta", "time_travel"}])
      assert problem(conn, 400)["code"] == "unsupported_beta_feature"
    end
  end

  describe "API-49 … API-51 rate limits" do
    test "API-49: responses carry the most restrictive tier in RateLimit and X-RateLimit headers",
         ctx do
      conn = advance(ctx.token, %{"by" => "PT1H"}, [key()])

      assert get_resp_header(conn, "ratelimit-policy") ==
               [~s("burst";q=200;w=1, "sustained";q=6000;w=60)]

      assert ["\"burst\";r=199;t=" <> _] = get_resp_header(conn, "ratelimit")
      assert get_resp_header(conn, "x-ratelimit-limit") == ["200"]
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["199"]
      assert [_] = get_resp_header(conn, "x-ratelimit-reset")
    end

    test "API-50: a batch weighs its rows", ctx do
      publish = Api.token(ctx.tenant.test, ["publish"])

      conn =
        :post
        |> Api.json("/v1/events/batch", publish, batch(7), [key()])
        |> Api.call()

      assert conn.status == 202
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["193"]
    end

    test "API-50: past the tenant's limit the answer is 429 rate_limited with Retry-After", ctx do
      {:ok, _} =
        Relay.Tenancy.put_setting(
          ctx.tenant.test,
          %{
            key: "api.rate.burst",
            value: %{"weight" => 2, "window_seconds" => 60},
            expected_version: nil,
            record_digest: TenantFixture.digest()
          },
          TenantFixture.actor()
        )

      assert advance(ctx.token, %{"by" => "PT1H"}, [key()]).status == 200
      assert advance(ctx.token, %{"by" => "PT1H"}, [key()]).status == 200

      limited = advance(ctx.token, %{"by" => "PT1H"}, [key()])
      body = problem(limited, 429)

      assert body["code"] == "rate_limited"
      assert body["retryable"] == true
      assert [retry] = get_resp_header(limited, "retry-after")
      assert String.to_integer(retry) == body["retry_after"]
      assert get_resp_header(limited, "x-ratelimit-remaining") == ["0"]
    end
  end

  describe "API-56 pagination" do
    test "API-56: a list answers the envelope; its cursor works in its own environment only",
         ctx do
      token = Api.token(ctx.tenant.test, ["read"])
      live = Api.token(ctx.tenant.live, ["read"])

      list = fn token, query ->
        :get
        |> Api.conn("/v1/notifications" <> query, nil, [{"authorization", "Bearer " <> token}])
        |> Api.call()
      end

      first = list.(token, "?limit=10")
      assert first.status == 200
      Api.assert_contract(first)
      next = Jason.decode!(first.resp_body)["next_cursor"]

      assert list.(token, "?starting_after=" <> next).status == 200
      assert problem(list.(live, "?starting_after=" <> next), 403)["code"] ==
               "auth_environment_mismatch"

      body = problem(list.(token, "?starting_after=garbage"), 422)
      assert [%{"pointer" => "/starting_after", "code" => "invalid_format"}] = body["errors"]
    end
  end

  defp batch(rows) do
    events = for i <- 1..rows, do: %{"workflow" => "welcome", "to" => ["u-#{i}"]}
    %{"events" => events}
  end
end
