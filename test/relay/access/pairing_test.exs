defmodule Relay.Access.PairingTest do
  use Relay.DataCase, async: false

  alias Relay.Access.Cache
  alias Relay.Access.Discovery
  alias Relay.Access.Pairing
  alias Relay.Access.Pairing.Job
  alias Relay.Access.Pairing.Store
  alias Relay.Access.Pairing.Streams
  alias Relay.Access.Pairing.Target
  alias Relay.Access.ServiceKey
  alias RelayTest.FakeAccess
  alias RelayTest.FakePairing
  alias RelayTest.TenantFixture

  @realm_a "00000000-0000-4000-8000-00000000000a"
  @realm_b "00000000-0000-4000-8000-00000000000b"
  @jobs "SELECT args FROM relay_queue.oban_jobs WHERE worker = 'Relay.Access.Pairing.Job' ORDER BY id"

  defmodule Signer do
    @moduledoc false
    @behaviour Relay.Access.Pairing.Signer

    @impl Relay.Access.Pairing.Signer
    def sign(target, _service_key, _now_ms) do
      register = if target.party_register, do: "placeholder-register-ais"
      {:ok, %{ais: "placeholder-ais", register_ais: register}}
    end
  end

  setup do
    :ok = Cache.forget(:_)
    test = self()
    id = make_ref()
    :ok = :telemetry.attach(id, [:relay, :access, :pairing], &__MODULE__.handle_event/4, test)
    on_exit(fn -> :telemetry.detach(id) end)
    %{tenant: TenantFixture.tenant!().attrs.access_tenant_id, fake: FakePairing.start!()}
  end

  @doc false
  def handle_event(_event, measurements, _meta, test), do: send(test, {:telemetry, measurements})

  defp run(scope, fake, opts \\ []),
    do: Pairing.run(scope, [http: [plug: {FakePairing, fake}]] ++ opts)

  defp signals(report, kind), do: for({^kind, meta} <- report.signals, do: meta)

  defp states(tenant), do: Enum.map(Store.realms(tenant), &{&1.realm, &1.state, &1.failed_runs})

  defp asked(tenant, count \\ 0) do
    receive do
      {:fake_pairing, :challenges, ^tenant} -> asked(tenant, count + 1)
    after
      0 -> count
    end
  end

  defp flush do
    receive do
      {:fake_pairing, _kind} -> flush()
      {:fake_pairing, _kind, _detail} -> flush()
      {:fake_pairing, _kind, _detail, _body} -> flush()
      {:telemetry, _measurements} -> flush()
    after
      0 -> :ok
    end
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  describe "E-101 the service key" do
    test "E-101: the kid is the RFC 7638 thumbprint of the Ed25519 public key" do
      hex = "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"
      key = Base.decode16!(hex, case: :lower)

      assert Base.encode16(ServiceKey.thumbprint(key), case: :lower) ==
               "5030d178e665d62a5701fa7dc18b26d77b0304c2b9a20fbe4167418f3b9fea8e"

      assert ServiceKey.jwk(key) == %{"kty" => "OKP", "crv" => "Ed25519", "x" => b64(key)}
    end

    test "E-101: the service key is printed as a JWK with its thumbprint as kid" do
      printed = ExUnit.CaptureIO.capture_io(fn -> :ok = ServiceKey.print_service_key() end)
      jwk = Jason.decode!(printed)
      {:ok, key} = ServiceKey.public_key()

      assert jwk == %{
               "kty" => "OKP",
               "crv" => "Ed25519",
               "x" => b64(key),
               "kid" => b64(ServiceKey.thumbprint(key)),
               "use" => "sig"
             }
    end
  end

  describe "E-101 discovery" do
    test "E-101: the Suiss configuration names the pairing routes and the platform streams" do
      issuer = FakeAccess.issuer()
      base = issuer <> "/access/v1"

      endpoints = %{
        "pairing_challenges" => base <> "/tenants/{tenant}/pairing/challenges",
        "pairing" => base <> "/tenants/{tenant}/pairing",
        "platform_streams" => base <> "/platform/streams"
      }

      document = Map.put(FakeAccess.suiss("tr"), "endpoints", endpoints)
      assert {:ok, suiss} = Discovery.parse_suiss(document, issuer)
      assert suiss.pairing_challenges == endpoints["pairing_challenges"]
      assert suiss.pairing == endpoints["pairing"]
      assert suiss.platform_streams == endpoints["platform_streams"]

      for {name, url} <- [
            {"pairing", base <> "/pairing"},
            {"pairing_challenges", "http://access.test/{tenant}/pairing/challenges"},
            {"platform_streams", base <> "/tenants/{tenant}/streams"},
            {"platform_streams", 42}
          ] do
        bad = Map.put(document, "endpoints", Map.put(endpoints, name, url))

        assert {:error, %Relay.Error{code: :access_discovery_invalid}} =
                 Discovery.parse_suiss(bad, issuer)
      end
    end
  end

  describe "E-101 challenge checks" do
    setup do
      now = System.system_time(:millisecond)
      challenge = :crypto.strong_rand_bytes(32)

      target = %{
        status: :unpaired,
        realm: @realm_a,
        domain: :crypto.strong_rand_bytes(32),
        basis: :crypto.strong_rand_bytes(16),
        pep: "access-identity",
        party: :crypto.strong_rand_bytes(16),
        kid: FakePairing.kid(),
        challenge: challenge,
        valid_from_ms: now - 1_000,
        valid_until_ms: now + 600_000,
        instance_create: %{nonce: challenge, intent: :crypto.strong_rand_bytes(32)},
        party_register: %{
          nonce: Target.register_nonce(challenge),
          intent: :crypto.strong_rand_bytes(32)
        }
      }

      %{target: target, now: now}
    end

    test "E-101: nothing is signed unless the kid, both nonces, the validity and the PEP hold",
         %{target: target, now: now} do
      kid = FakePairing.kid()
      assert Target.check(target, kid, now) == :ok
      assert Target.check(%{target | party_register: nil}, kid, now) == :ok
      assert Target.register_nonce(<<7>>) == <<7, 1>>

      for {broken, code} <- [
            {%{target | kid: :crypto.strong_rand_bytes(32)}, "pairing-kid"},
            {put_in(target.instance_create.nonce, <<0::256>>), "pairing-nonce"},
            {put_in(target.party_register.nonce, target.challenge <> <<2>>),
             "pairing-register-nonce"},
            {%{target | valid_until_ms: now + 59_999}, "pairing-validity"},
            {%{target | valid_from_ms: now + 700_000}, "pairing-validity"},
            {%{target | pep: ""}, "pairing-pep"},
            {%{target | pep: String.duplicate("p", 256)}, "pairing-pep"}
          ] do
        assert Target.check(broken, kid, now) == {:error, code}
      end

      assert Target.check(%{target | valid_until_ms: now + 60_000}, kid, now) == :ok
    end

    test "E-101: an answer is read only whole: its tenant, distinct realms and every member" do
      wire = %{
        "realm" => @realm_a,
        "status" => "paired",
        "party" => b64(<<1::128>>),
        "instance" => b64(<<2::128>>),
        "kid" => b64(<<3::256>>)
      }

      answer = %{"tenant" => "tnt_1", "targets" => [wire], "event_stream" => @realm_b}
      assert {:ok, %{event_stream: @realm_b, targets: [%{status: :paired}]}} =
               Target.parse(answer, "tnt_1")

      for bad <- [
            %{answer | "tenant" => "tnt_2"},
            %{answer | "targets" => [wire, wire]},
            %{answer | "event_stream" => "stream"},
            %{answer | "targets" => [%{wire | "realm" => String.upcase(@realm_a)}]},
            %{answer | "targets" => [%{wire | "party" => b64(<<1::120>>)}]},
            %{answer | "targets" => [%{wire | "status" => "gone"}]},
            %{answer | "targets" => [%{"realm" => @realm_a, "status" => "refused"}]}
          ] do
        assert Target.parse(bad, "tnt_1") == :error
      end

      assert Target.time_ms("2026-11-05T09:00:00.000Z") == {:ok, 1_793_869_200_000}
      assert Target.time_ms("2026-11-05T09:00:00.5Z") == {:ok, 1_793_869_200_500}
      assert Target.time_ms("2026-11-05T09:00:00.0001Z") == :error
      assert Target.time_ms("2026-11-05T12:00:00+03:00") == :error

      signed = %{realm: @realm_a, challenge: <<1::256>>, ais: "a", register_ais: nil}
      assert {:ok, %{"targets" => [one]}} = Target.pairing_body([signed])
      assert one == %{"realm" => @realm_a, "challenge" => b64(<<1::256>>), "ais" => b64("a")}
      assert {:ok, _body} = Target.pairing_body(List.duplicate(signed, 64))
      assert Target.pairing_body(List.duplicate(signed, 65)) == :error
      assert Target.pairing_body([]) == :error
    end
  end

  describe "E-101 pairing runs" do
    test "E-101: without the Access kernel nothing is signed and three runs in a row are an operator signal",
         ctx do
      report = run({:tenant, ctx.tenant}, ctx.fake)

      assert asked(ctx.tenant) == 1
      refute_received {:fake_pairing, :pairing, _tenant, _body}
      assert report.tenants == 1
      assert report.paired == 0

      assert Enum.map(signals(report, :unsignable), &{&1.realm, &1.code}) == [
               {@realm_a, "kernel-unavailable"},
               {@realm_b, "kernel-unavailable"}
             ]

      assert states(ctx.tenant) == [{@realm_a, :unpaired, 1}, {@realm_b, :unpaired, 1}]
      assert_received {:telemetry, %{unpaired_realms: 0}}

      _second = run(:due, ctx.fake)
      third = run(:due, ctx.fake)

      assert Enum.map(signals(third, :unpaired), &{&1.realm, &1.runs}) == [
               {@realm_a, 3},
               {@realm_b, 3}
             ]

      assert third.unpaired_realms == 2
      assert_received {:telemetry, %{unpaired_realms: 2}}
    end

    test "E-101: signed challenges pair every realm, the stream is adopted and a due run then asks nothing",
         ctx do
      report = run({:tenant, ctx.tenant}, ctx.fake, signer: Signer)
      tenant = ctx.tenant

      assert_received {:fake_pairing, :pairing, ^tenant, %{"targets" => targets}}
      assert Enum.map(targets, & &1["realm"]) == [@realm_a, @realm_b]

      for target <- targets do
        assert target["ais"] == b64("placeholder-ais")
        assert target["register_ais"] == b64("placeholder-register-ais")
        assert {:ok, <<_::256>>} = Base.url_decode64(target["challenge"], padding: false)
      end

      assert report.paired == 2
      assert report.signals == []
      assert report.stream_up
      assert states(ctx.tenant) == [{@realm_a, :paired, 0}, {@realm_b, :paired, 0}]
      stream = report.event_stream
      assert_received {:fake_pairing, :stream, ^stream}
      refute_received {:fake_pairing, :open_stream, _body}
      assert %{stream: ^stream, status: :enabled, recreated: 0} = Store.stream()

      flush()
      due = run(:due, ctx.fake, signer: Signer)
      assert asked(tenant) == 0
      assert due.tenants >= 1
      assert due.stream_up
      assert_received {:fake_pairing, :stream, ^stream}
      assert_received {:telemetry, %{unpaired_realms: 0, stream_up: 1}}

      flush()
      _all = run(:all, ctx.fake, signer: Signer)
      assert asked(tenant) == 1
      refute_received {:fake_pairing, :pairing, ^tenant, _body}
    end

    test "E-101: a challenge that fails a check is not signed and counts a failed run", ctx do
      for {tamper, code} <- [
            kid: "pairing-kid",
            nonce: "pairing-nonce",
            register_nonce: "pairing-register-nonce",
            validity: "pairing-validity"
          ] do
        fake = FakePairing.start!(tamper: tamper)
        tenant = TenantFixture.tenant!().attrs.access_tenant_id
        report = run({:tenant, tenant}, fake, signer: Signer)

        refute_received {:fake_pairing, :pairing, ^tenant, _body}
        assert Enum.map(signals(report, :unsignable), & &1.code) == [code, code]
        assert states(tenant) == [{@realm_a, :unpaired, 1}, {@realm_b, :unpaired, 1}]
      end
    end

    test "E-101: a 503 or an invalid challenge is tried once more with a new challenge, nothing else",
         ctx do
      for failure <- [{503, nil}, {400, "invalid-challenge"}] do
        fake = FakePairing.start!(challenge_failures: [failure])
        tenant = TenantFixture.tenant!().attrs.access_tenant_id
        report = run({:tenant, tenant}, fake, signer: Signer)

        assert asked(tenant) == 2
        assert report.paired == 2
        assert signals(report, :failed) == []
      end

      fake = FakePairing.start!(challenge_failures: [{503, nil}, {503, nil}])
      report = run({:tenant, ctx.tenant}, fake, signer: Signer)
      assert asked(ctx.tenant) == 2
      assert [%{tenant: tenant, error: {:refused, 503, nil}}] = signals(report, :failed)
      assert tenant == ctx.tenant
      assert states(ctx.tenant) == [{@realm_a, :unpaired, 1}, {@realm_b, :unpaired, 1}]

      fake = FakePairing.start!(challenge_failures: [{400, "invalid-request"}])
      other = TenantFixture.tenant!().attrs.access_tenant_id
      report = run({:tenant, other}, fake, signer: Signer)
      assert asked(other) == 1
      assert [%{error: {:refused, 400, "invalid-request"}}] = signals(report, :failed)
    end

    test "E-101: a refused realm is reported with its slug, and its pairing later clears it",
         ctx do
      fake = FakePairing.start!(refused: [@realm_a])
      report = run({:tenant, ctx.tenant}, fake, signer: Signer)

      assert [%{realm: @realm_a, slug: slug, code: "realm-closed"}] = signals(report, :refused)
      assert slug == ctx.tenant <> "-a"
      assert states(ctx.tenant) == [{@realm_a, :refused, 1}, {@realm_b, :paired, 0}]

      FakePairing.update(fake, &%{&1 | refused: MapSet.new()})
      report = run({:tenant, ctx.tenant}, fake, signer: Signer)

      assert [%{realm: @realm_a, slug: ^slug}] = signals(report, :cleared)
      assert states(ctx.tenant) == [{@realm_a, :paired, 0}, {@realm_b, :paired, 0}]
    end

    test "E-101: realms that leave the snapshot are retired, never deleted", ctx do
      _stored = Store.seen(ctx.tenant, [{"00000000-0000-4000-8000-0000000000ff", "gone"}])
      _report = run({:tenant, ctx.tenant}, ctx.fake)

      assert Enum.map(Store.realms(ctx.tenant), &{&1.realm, &1.state}) == [
               {@realm_a, :unpaired},
               {@realm_b, :unpaired},
               {"00000000-0000-4000-8000-0000000000ff", :retired}
             ]
    end
  end

  describe "E-101 the event stream" do
    test "E-101: a paused stream is a warning and is left as it is" do
      fake = FakePairing.start!(streams: [FakePairing.stream(@realm_b, "paused")])
      report = run(:due, fake)

      assert [%{stream: @realm_b, status: :paused}] = signals(report, :stream_down)
      refute_received {:fake_pairing, :open_stream, _body}
      refute report.stream_up
      assert %{stream: @realm_b, status: :paused} = Store.stream()
    end

    test "E-101: a disabled or missing stream is opened again with the events of a known stream" do
      fake = FakePairing.start!(streams: [FakePairing.stream(@realm_b, "disabled")])
      report = run(:due, fake)

      assert_received {:fake_pairing, :open_stream, body}

      assert body == %{
               "delivery" => %{
                 "method" => "urn:ietf:rfc:8935",
                 "endpoint_url" => FakePairing.receiver()
               },
               "aud" => Relay.Access.client_id(),
               "events_requested" => ["urn:suiss:access:event:tenant.created"]
             }

      assert [%{stream: stream}] = signals(report, :stream_recreated)
      assert report.stream_up
      assert %{stream: ^stream, status: :enabled, recreated: 1} = Store.stream()

      FakePairing.update(fake, &%{&1 | streams: []})
      flush()
      _report = run(:due, fake)
      assert_received {:fake_pairing, :stream, ^stream}
      assert_received {:fake_pairing, :open_stream, %{"events_requested" => events}}
      assert events == Streams.catalog()
      assert %{recreated: 2} = Store.stream()
    end

    test "E-101: when Access already holds a live stream, Relay adopts it" do
      fake = FakePairing.start!(streams: [FakePairing.stream(@realm_a, "enabled")])
      _recreated = Store.record_stream(@realm_b, :enabled, false)
      report = run(:due, fake)

      assert_received {:fake_pairing, :stream, @realm_b}
      assert_received {:fake_pairing, :open_stream, _body}
      assert signals(report, :stream_recreated) == []
      assert report.stream_up
      assert %{stream: @realm_a, status: :enabled, recreated: 0} = Store.stream()
    end
  end

  describe "E-101 triggers" do
    test "E-101: a scope's run is queued once, and tenant.created queues one for its tenant" do
      :ok = FakeAccess.install!()
      assert :ok = Pairing.request(:all)
      assert :ok = Pairing.request(:all)
      access_tenant = "acc_" <> FakeAccess.random()

      data = %{
        "access_tenant_id" => access_tenant,
        "region" => FakeAccess.installation_region(),
        "default_timezone" => "Europe/Istanbul",
        "default_locale" => "tr-TR"
      }

      assert FakeAccess.deliver(FakeAccess.event("tenant.created", data)).status == 202
      _applied = FakeAccess.drain!()

      assert Enum.map(Relay.Repo.query!(@jobs, []).rows, &hd/1) == [
               %{"scope" => "all"},
               %{"scope" => "tenant", "tenant" => access_tenant}
             ]

      assert Job.args(:due) == %{"scope" => "due"}
    end

    test "E-101: without discovery of the pairing routes a run reports the failure and changes nothing",
         ctx do
      report = Pairing.run({:tenant, ctx.tenant})

      assert [%{tenant: nil, error: %Relay.Error{code: :access_discovery_invalid}}] =
               signals(report, :failed)

      assert Store.realms(ctx.tenant) == []
      assert_received {:telemetry, %{unpaired_realms: 0, stream_up: 0}}
    end
  end
end
