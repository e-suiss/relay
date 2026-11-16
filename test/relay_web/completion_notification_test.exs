defmodule RelayWeb.CompletionNotificationTest do
  use Relay.DataCase, async: false

  alias Relay.Webhooks.Profile
  alias RelayTest.Api
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @worker "Relay.Webhooks.CompletionWorker"
  @sources "/v1/webhook_sources"
  @missing "whs_01j9zq3k4m5n6p7q8r9s0t1v2w"

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    %{
      scope: scope,
      token: F.token(scope),
      public_key: "whpk_" <> Base.encode64(public_key),
      private_key: private_key
    }
  end

  defp post(ctx, path, body, status), do: F.body(F.request(:post, path, ctx.token, body), status)
  defp get(ctx, path, status \\ 200), do: F.body(F.request(:get, path, ctx.token), status)

  defp source!(ctx, name \\ "executor"),
    do: post(ctx, @sources, %{"name" => name, "public_key" => ctx.public_key}, 201)

  defp secret!(scope, kind, value) do
    var = "RELAY_TEST_SOURCE_" <> String.upcase(TenantFixture.random())
    System.put_env(var, value)
    on_exit(fn -> System.delete_env(var) end)
    id = Relay.Id.generate()

    attrs = %{
      id: id,
      kind: kind,
      ref: "${#{var}}",
      ref_version: 1,
      record_digest: TenantFixture.digest()
    }

    {:ok, :created} = Relay.Secrets.register(scope, attrs, TenantFixture.actor())
    Relay.ExternalId.encode("sec", id)
  end

  defp waitpoint!(scope, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          id: Relay.Id.generate(),
          kind: :event,
          waiter_kind: :agent,
          waiter_ref: TenantFixture.recipient!(scope, %{}, kind: :agent),
          match_event_type: "job.finished",
          correlation_key: "job-" <> TenantFixture.random(),
          expires_at: DateTime.add(Relay.Clock.business_now(scope), 1, :hour)
        },
        overrides
      )

    {:ok, %{result: :opened, waitpoint_id: id}} = Relay.Agents.open_waitpoint(scope, attrs)
    id
  end

  defp state(scope, waitpoint_id) do
    {:ok, %{state: state}} = Relay.Agents.get_waitpoint(scope, waitpoint_id)
    state
  end

  defp reference(waitpoint_id), do: Relay.ExternalId.encode("wp", waitpoint_id)

  defp notification(waitpoint_id, overrides \\ %{}) do
    %{
      "specversion" => "1.0",
      "id" => "evt-" <> TenantFixture.random(),
      "source" => "urn:executor:jobs",
      "type" => "job.completed",
      "time" => "2026-11-16T10:00:00Z",
      "datacontenttype" => "application/json",
      "data" => %{"waitpoint_id" => reference(waitpoint_id), "result" => %{"rows" => 42}}
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  defp now, do: DateTime.to_unix(Relay.Clock.utc_now())

  defp ed25519(private_key, id, timestamp, body) do
    content = Profile.signed_content(id, timestamp, body)
    signature = :crypto.sign(:eddsa, :none, content, [private_key, :ed25519])
    Profile.headers(id, timestamp, [Profile.token(:v1a, signature)])
  end

  defp hmac(secret, id, timestamp, body),
    do: Profile.headers(id, timestamp, [Profile.hmac_token(secret, id, timestamp, body)])

  defp deliver(scope, source_id, body, headers) do
    tenant = Relay.ExternalId.encode("ten", scope.tenant_id)
    environment = Atom.to_string(scope.environment)
    path = "/inbound/v1/completions/#{tenant}/#{environment}/sources/#{source_id}"
    type = {"content-type", "application/cloudevents+json"}
    Api.call(Api.conn(:post, path, body, [type | headers]), RelayWeb.Router)
  end

  defp send!(ctx, source, body, id \\ "msg-1") do
    headers = ed25519(ctx.private_key, id, now(), body)
    deliver(ctx.scope, source["id"], body, headers).status
  end

  defp jobs(scope), do: F.jobs(@worker, scope, "receipt_id")

  defp process(scope) do
    for [text] <- jobs(scope) do
      {:ok, id} = Relay.Id.parse(text)
      {:ok, result} = Relay.Webhooks.process_completion(scope, id)
      result
    end
  end

  describe "WH-68 completion sources" do
    test "WH-68: a source is registered with its public key, listed, read and archived", ctx do
      created = source!(ctx)

      assert %{"object" => "webhook_source", "scheme" => "v1a", "state" => "active"} = created
      assert created["public_key"] == ctx.public_key
      assert created["secret_ref_id"] == nil
      assert "whs_" <> _ = created["id"]

      path = @sources <> "/" <> created["id"]
      assert get(ctx, path) == created
      assert Enum.map(get(ctx, @sources)["data"], & &1["id"]) == [created["id"]]

      archived = post(ctx, path <> "/archive", nil, 200)
      assert %{"state" => "archived", "archived_at" => at} = archived
      assert is_binary(at)
      assert post(ctx, path <> "/archive", nil, 200)["state"] == "archived"
      assert get(ctx, @sources <> "?state=active")["data"] == []
      assert [%{"state" => "archived"}] = get(ctx, @sources <> "?state=archived")["data"]

      missing = @sources <> "/" <> @missing
      assert get(ctx, missing, 404)["code"] == "webhook_source_not_found"
      assert post(ctx, missing <> "/archive", nil, 404)["code"] == "webhook_source_not_found"
    end

    test "WH-68: a source names exactly one of its public key and its secret reference", ctx do
      secret = "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))
      ref = secret!(ctx.scope, :webhook_signing, secret)

      both = %{"name" => "both", "public_key" => ctx.public_key, "secret_ref_id" => ref}
      refused = post(ctx, @sources, both, 422)
      assert [%{"pointer" => "/secret_ref_id"}] = refused["errors"]

      neither = post(ctx, @sources, %{"name" => "neither"}, 422)
      assert [%{"pointer" => "/public_key", "code" => "required"}] = neither["errors"]
      assert get(ctx, @sources)["data"] == []
    end

    test "WH-68, TN-26: a v1 source holds the reference of its secret, never the secret", ctx do
      secret = "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))
      ref = secret!(ctx.scope, :webhook_signing, secret)

      conn = F.request(:post, @sources, ctx.token, %{"name" => "hmac", "secret_ref_id" => ref})
      created = F.body(conn, 201)
      assert %{"scheme" => "v1", "public_key" => nil, "secret_ref_id" => ^ref} = created
      refute conn.resp_body =~ secret

      destination = secret!(ctx.scope, :webhook_destination, "client-secret")
      wrong = post(ctx, @sources, %{"name" => "wrong", "secret_ref_id" => destination}, 422)
      assert [%{"pointer" => "/secret_ref_id", "code" => "not_found"}] = wrong["errors"]

      unknown = Relay.ExternalId.encode("sec", Relay.Id.generate())
      missing = post(ctx, @sources, %{"name" => "unknown", "secret_ref_id" => unknown}, 422)
      assert missing["code"] == "validation_failed"
    end

    test "WH-68: an environment holds at most 20 sources that are not archived", ctx do
      sources = for n <- 1..20, do: source!(ctx, "s#{n}")

      body = %{"name" => "s21", "public_key" => ctx.public_key}
      assert post(ctx, @sources, body, 422)["code"] == "webhook_source_limit_reached"

      post(ctx, @sources <> "/" <> hd(sources)["id"] <> "/archive", nil, 200)
      assert post(ctx, @sources, body, 201)["name"] == "s21"
    end
  end

  describe "WH-68 inbound completion notifications" do
    test "WH-68, WH-50: a verified notification is committed and completes its waitpoint", ctx do
      source = source!(ctx)
      waitpoint_id = waitpoint!(ctx.scope)
      body = notification(waitpoint_id)

      headers = ed25519(ctx.private_key, "msg-1", now(), body)
      conn = deliver(ctx.scope, source["id"], body, headers)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}
      assert [[_receipt_id]] = jobs(ctx.scope)
      assert state(ctx.scope, waitpoint_id) == "open"

      assert process(ctx.scope) == [:resolved]
      assert state(ctx.scope, waitpoint_id) == "resolved"
    end

    test "WH-68: a job.failed notification ends the wait as well", ctx do
      source = source!(ctx)
      waitpoint_id = waitpoint!(ctx.scope)

      assert send!(ctx, source, notification(waitpoint_id, %{"type" => "job.failed"})) == 200
      assert process(ctx.scope) == [:resolved]
      assert state(ctx.scope, waitpoint_id) == "resolved"
    end

    test "WH-68, WH-49: a repeated webhook-id is acknowledged and not processed again", ctx do
      source = source!(ctx)
      body = notification(waitpoint!(ctx.scope))

      assert send!(ctx, source, body) == 200
      assert send!(ctx, source, body) == 200
      assert [[_receipt_id]] = jobs(ctx.scope)

      assert process(ctx.scope) == [:resolved]
      assert send!(ctx, source, body) == 200
      assert [[_receipt_id]] = jobs(ctx.scope)
      assert process(ctx.scope) == [:skipped]

      assert send!(ctx, source!(ctx, "other"), body) == 200
      assert [[_first], [_second]] = jobs(ctx.scope)
    end

    test "WH-68: an unknown reference and a settled waitpoint are accepted with no effect", ctx do
      source = source!(ctx)

      assert send!(ctx, source, notification(Relay.Id.generate())) == 200
      assert process(ctx.scope) == [:not_found]

      waitpoint_id = waitpoint!(ctx.scope)
      {:ok, :resolved} = Relay.Agents.complete_waitpoint(ctx.scope, waitpoint_id)

      assert send!(ctx, source, notification(waitpoint_id), "msg-2") == 200
      assert process(ctx.scope) == [:skipped, :already_terminal]
      assert state(ctx.scope, waitpoint_id) == "resolved"
    end

    test "WH-68, T-40: a notification that does not verify is refused and has no effect", ctx do
      %{scope: scope, private_key: key} = ctx
      id = source!(ctx)["id"]
      waitpoint_id = waitpoint!(scope)
      body = notification(waitpoint_id)
      headers = ed25519(key, "msg-1", now(), body)

      {_public_key, other_key} = :crypto.generate_key(:eddsa, :ed25519)
      tampered = notification(waitpoint_id, %{"type" => "job.failed"})

      assert deliver(scope, id, body, ed25519(other_key, "msg-1", now(), body)).status == 401
      assert deliver(scope, id, tampered, headers).status == 401
      assert deliver(scope, id, body, ed25519(key, "msg-1", now() - 600, body)).status == 401
      assert deliver(scope, id, body, []).status == 401

      refused = deliver(scope, id, body, List.keydelete(headers, "webhook-signature", 0))
      assert refused.status == 401
      assert Jason.decode!(refused.resp_body) == %{"error" => "unauthorized"}

      assert jobs(scope) == []
      assert state(scope, waitpoint_id) == "open"
    end

    test "WH-68: a verified body that is not a notification leaves no receipt", ctx do
      source = source!(ctx)
      waitpoint_id = waitpoint!(ctx.scope)
      data = %{"waitpoint_id" => reference(waitpoint_id)}
      large = Map.put(data, "result", %{"blob" => String.duplicate("x", 4096)})

      bodies = [
        "not json",
        notification(waitpoint_id, %{"type" => "job.started"}),
        notification(waitpoint_id, %{"specversion" => "0.3"}),
        notification(waitpoint_id, %{"data" => %{"waitpoint_id" => "wp_nothing"}}),
        notification(waitpoint_id, %{"data" => Map.put(data, "other", 1)}),
        notification(waitpoint_id, %{"data" => large})
      ]

      for {body, n} <- Enum.with_index(bodies) do
        headers = ed25519(ctx.private_key, "msg-#{n}", now(), body)
        conn = deliver(ctx.scope, source["id"], body, headers)
        assert conn.status == 400
        assert Jason.decode!(conn.resp_body) == %{"error" => "malformed"}
      end

      assert jobs(ctx.scope) == []
      assert state(ctx.scope, waitpoint_id) == "open"
    end

    test "WH-68: a waitpoint that waits with a condition is not completed", ctx do
      source = source!(ctx)

      conditional =
        waitpoint!(ctx.scope, %{
          waiter_kind: :subscriber,
          waiter_ref: TenantFixture.recipient!(ctx.scope, %{}),
          condition: %{"field" => "incoming.ok", "op" => "eq", "value" => true}
        })

      assert send!(ctx, source, notification(conditional)) == 200
      assert process(ctx.scope) == [:not_completable]
      assert state(ctx.scope, conditional) == "open"
    end

    test "WH-68: an archived, an unknown and another tenant's source are not found", ctx do
      source = source!(ctx)
      waitpoint_id = waitpoint!(ctx.scope)
      body = notification(waitpoint_id)
      headers = ed25519(ctx.private_key, "msg-1", now(), body)

      other = TenantFixture.tenant!().test
      assert deliver(other, source["id"], body, headers).status == 404
      assert deliver(ctx.scope, @missing, body, headers).status == 404
      assert deliver(ctx.scope, "nothing", body, headers).status == 404

      post(ctx, @sources <> "/" <> source["id"] <> "/archive", nil, 200)
      assert deliver(ctx.scope, source["id"], body, headers).status == 404
      assert jobs(ctx.scope) == []
      assert state(ctx.scope, waitpoint_id) == "open"
    end

    test "WH-68, TN-26: a v1 source is verified with the secret its reference resolves to", ctx do
      %{scope: scope} = ctx
      secret = :crypto.strong_rand_bytes(32)
      ref = secret!(scope, :webhook_signing, "whsec_" <> Base.encode64(secret))
      id = post(ctx, @sources, %{"name" => "hmac", "secret_ref_id" => ref}, 201)["id"]
      waitpoint_id = waitpoint!(scope)
      body = notification(waitpoint_id)
      at = now()

      assert deliver(scope, id, body, hmac("another secret", "msg-1", at, body)).status == 401
      assert deliver(scope, id, body, ed25519(ctx.private_key, "msg-1", at, body)).status == 401
      assert jobs(scope) == []

      assert deliver(scope, id, body, hmac(secret, "msg-1", at, body)).status == 200
      assert process(scope) == [:resolved]
      assert state(scope, waitpoint_id) == "resolved"
    end
  end
end
