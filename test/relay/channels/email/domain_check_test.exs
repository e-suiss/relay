defmodule Relay.Channels.Email.FakeResolver do
  @behaviour Relay.Channels.Email.Resolver

  def put(zone), do: Process.put(__MODULE__, zone)

  @impl Relay.Channels.Email.Resolver
  def txt(name), do: answer({:txt, name})

  @impl Relay.Channels.Email.Resolver
  def cname(name), do: answer({:cname, name})

  @impl Relay.Channels.Email.Resolver
  def lookup(name, type), do: answer({type, name})

  defp answer(key) do
    case Map.fetch(Process.get(__MODULE__, %{}), key) do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, value} -> {:ok, value}
      :error -> {:error, :nxdomain}
    end
  end
end

defmodule Relay.Channels.Email.DomainCheckTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Email.Dkim
  alias Relay.Channels.Email.Dmarc
  alias Relay.Channels.Email.DomainCheck
  alias Relay.Channels.Email.FakeResolver
  alias Relay.Channels.Email.Spf

  @now ~U[2026-11-05 12:00:00Z]
  @short_p "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDkHlOQoBTzWRiGs5V6NpP3idY6Wk08a5qhdR6wy5bdOKb2jLQiY/J16JYi0Qvx/byYzCNb3W91y3FutACDfzwQ/BC/e/8uBsCR+yz1Lxj+PL6lHvqMKrM3rG4hstT5QjvHO9PzoxZyVYLzBfO2EeC3Ip3G+2kryOTIKT+l/K4w3QIDAQAB"

  setup_all do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    key = rsa_key(private)
    %{key: key, record: Dkim.dns_record(key)}
  end

  defp zone(ctx, overrides \\ %{}) do
    %{
      {:txt, "tx.sender.example"} => [["v=spf1 include:_spf.esp.example -all"]],
      {:txt, "_spf.esp.example"} => [
        ["v=spf1 ip4:192.0.2.0/24 ", "include:_spf2.esp.example ~all"],
        ["google-site-verification=abc"]
      ],
      {:txt, "_spf2.esp.example"} => [["v=spf1 ip4:198.51.100.0/24 -all"]],
      {:txt, "tx2026a._domainkey.tx.sender.example"} => [ctx.record],
      {:txt, "tx2026b._domainkey.tx.sender.example"} => [ctx.record],
      {:txt, "_dmarc.sender.example"} => [["v=DMARC1; p=reject; adkim=s; aspf=s; np=reject"]],
      {:cname, "bounce.tx.sender.example"} => "bounce.relay.example"
    }
    |> Map.merge(overrides)
    |> FakeResolver.put()
  end

  defp input(ctx, extra \\ %{}) do
    Map.merge(
      %{
        domain: "tx.sender.example",
        stream: "transactional",
        return_path_domain: "bounce.tx.sender.example",
        return_path_target: "bounce.relay.example.",
        selectors: [
          %{
            selector: "tx2026a",
            stream: "transactional",
            state: :active,
            activated_at: ~U[2026-09-01 00:00:00Z],
            public_key: ctx.key
          },
          %{selector: "mkt2026a", stream: "marketing", state: :active, activated_at: @now}
        ]
      },
      extra
    )
  end

  defp run(ctx, extra \\ %{}), do: DomainCheck.run(input(ctx, extra), FakeResolver, @now)
  defp check(entry), do: DomainCheck.check_selector("tx.sender.example", entry, FakeResolver)
  defp selector(ctx), do: hd(input(ctx).selectors)

  defp entry(name, stream, state, at),
    do: %{selector: name, stream: stream, state: state, activated_at: at}

  defp rsa_key(private),
    do: {:binary.encode_unsigned(elem(private, 2)), :binary.encode_unsigned(elem(private, 3))}

  defp codes(result), do: Enum.map(result.findings, & &1.code)
  defp errors(result), do: for(%{severity: :error, code: code} <- result.findings, do: code)

  describe "CH-36 a verified domain" do
    test "INV-43: a domain with SPF, return path, DKIM and DMARC in order is verified", ctx do
      zone(ctx)
      result = run(ctx)

      assert result.verified
      assert result.findings == []
      assert result.spf.lookups == 2
      assert result.spf.void_lookups == 0
      assert %{name: "sender.example", policy: "reject"} = result.dmarc
      assert result.dmarc.org_domain == "sender.example"
    end

    test "CH-36: a domain shared by both streams gets a subdomain suggestion", ctx do
      zone(ctx)
      result = run(ctx, %{other_stream_domain: "TX.sender.example"})

      assert result.verified
      assert [%{severity: :suggestion, code: :stream_subdomain}] = result.findings
    end
  end

  describe "CH-36 SPF limits" do
    test "CH-36: more than 10 DNS-querying terms is an spf_lookup_limit error", ctx do
      includes = for n <- 1..11, do: "include:i#{n}.esp.example"
      chained = Map.new(1..11, &{{:txt, "i#{&1}.esp.example"}, [["v=spf1 -all"]]})
      record = Enum.join(["v=spf1" | includes] ++ ["-all"], " ")
      zone(ctx, Map.put(chained, {:txt, "tx.sender.example"}, [[record]]))

      result = run(ctx)
      assert result.spf.lookups == 11
      assert :spf_lookup_limit in errors(result)
      refute result.verified
    end

    test "CH-36: more than 2 void lookups is an spf_void_limit error", ctx do
      record = "v=spf1 a:gone1.example mx:gone2.example exists:gone3.example -all"
      zone(ctx, %{{:txt, "tx.sender.example"} => [[record]]})

      assert %{lookups: 3, void_lookups: 3, errors: [:spf_void_limit]} =
               Spf.check("tx.sender.example", FakeResolver)
    end

    test "CH-36: a missing, doubled or looping SPF record is an error", ctx do
      zone(ctx, %{{:txt, "tx.sender.example"} => {:error, :no_data}})
      assert %{errors: [:spf_missing]} = Spf.check("tx.sender.example", FakeResolver)

      zone(ctx, %{{:txt, "tx.sender.example"} => [["v=spf1 -all"], ["v=spf1 ~all"]]})
      assert %{errors: [:spf_multiple]} = Spf.check("tx.sender.example", FakeResolver)

      zone(ctx, %{{:txt, "tx.sender.example"} => [["v=spf1 include:tx.sender.example -all"]]})
      assert %{errors: [:spf_loop]} = Spf.check("tx.sender.example", FakeResolver)
    end

    test "CH-36: ptr and macros are counted and warned about", ctx do
      zone(ctx, %{{:txt, "tx.sender.example"} => [["v=spf1 ptr exists:%{i}.rbl.example -all"]]})
      result = Spf.check("tx.sender.example", FakeResolver)

      assert result.lookups == 2
      assert result.warnings == [:spf_ptr, :spf_macro]
      assert result.errors == []
    end
  end

  describe "CH-36 DKIM records" do
    test "CH-36: a 2048-bit key published as several strings is accepted", ctx do
      assert length(ctx.record) >= 2
      zone(ctx)
      assert check(selector(ctx)) == []
    end

    test "CH-36: a key under 2048 bits is refused, and p=reject then requires DKIM", ctx do
      short = [["v=DKIM1; k=rsa; p=" <> @short_p]]
      zone(ctx, %{{:txt, "tx2026a._domainkey.tx.sender.example"} => short})
      result = run(ctx, %{selectors: [%{selector(ctx) | public_key: nil}]})
      assert :dkim_key_too_short in errors(result)
      assert :dmarc_reject_requires_dkim in errors(result)
    end

    test "CH-36: a long record split into two TXT records instead of two strings is malformed",
         ctx do
      [first, second] = Enum.take(ctx.record, 2)
      zone(ctx, %{{:txt, "tx2026a._domainkey.tx.sender.example"} => [[first], [second]]})

      assert [%{code: :dkim_malformed}] = check(selector(ctx))
    end

    test "CH-36: a record that allows only SHA-1, a revoked key and a missing record are errors",
         ctx do
      unkeyed = %{selector(ctx) | public_key: nil}
      name = {:txt, "tx2026a._domainkey.tx.sender.example"}
      ed25519 = "v=DKIM1; k=ed25519; p=11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="

      cases = [
        {[["v=DKIM1; k=rsa; h=sha1; p=" <> @short_p]], :dkim_sha1_only},
        {[["v=DKIM1; k=rsa; p="]], :dkim_revoked},
        {[[ed25519]], :dkim_unsupported_key_type},
        {{:error, :nxdomain}, :dkim_missing}
      ]

      for {records, code} <- cases do
        zone(ctx, %{name => records})
        assert [%{code: ^code}] = check(unkeyed)
      end
    end

    test "CH-36: a published key that is not the key store's key is a mismatch", ctx do
      other = rsa_key(:public_key.generate_key({:rsa, 2048, 65_537}))
      zone(ctx)
      assert [%{code: :dkim_key_mismatch}] = check(%{selector(ctx) | public_key: other})
    end
  end

  describe "CH-36 selectors" do
    test "CH-36: a selector shared between streams is refused" do
      selectors = [
        entry("s1", "transactional", :active, @now),
        entry("S1", "marketing", :active, @now)
      ]

      assert [%{code: :dkim_selector_shared}] =
               DomainCheck.selectors(selectors, "transactional", @now)
    end

    test "CH-36: an active selector is due for rotation six months after activation" do
      due = entry("old", "transactional", :active, ~U[2026-05-05 12:00:00Z])
      fresh = %{due | activated_at: ~U[2026-05-06 12:00:00Z]}
      next = %{fresh | selector: "next", state: :next}

      assert DomainCheck.rotation_due?(due, @now)
      refute DomainCheck.rotation_due?(fresh, @now)

      assert [%{severity: :warning, code: :dkim_rotation_due}] =
               DomainCheck.selectors([due, next], "transactional", @now)
    end

    test "CH-36: a stream without an active selector is an error" do
      selectors = [entry("n1", "transactional", :next, nil)]

      assert [%{code: :dkim_no_active_selector}] =
               DomainCheck.selectors(selectors, "transactional", @now)
    end
  end

  describe "CH-36 return path" do
    test "CH-36: the return path must be a CNAME to Relay's bounce host", ctx do
      zone(ctx, %{{:cname, "bounce.tx.sender.example"} => "elsewhere.example"})
      assert :return_path_cname_mismatch in codes(run(ctx))

      zone(ctx, %{{:cname, "bounce.tx.sender.example"} => {:error, :nxdomain}})
      assert :return_path_cname_missing in codes(run(ctx))
    end

    test "CH-36: a return path outside the organizational domain is unaligned", ctx do
      zone(ctx, %{{:cname, "bounce.other.example"} => "bounce.relay.example"})
      result = run(ctx, %{return_path_domain: "bounce.other.example"})
      assert :return_path_unaligned in codes(result)
    end
  end

  describe "CH-36 DMARCbis tree walk" do
    test "CH-36: the walk drops one label at a time, from eight labels on to the last seven" do
      assert Dmarc.targets("a.b.example.com") ==
               ["a.b.example.com", "b.example.com", "example.com", "com"]

      deep = "l1.l2.l3.l4.l5.l6.l7.l8.example"
      assert [^deep, "l3.l4.l5.l6.l7.l8.example" | _rest] = Dmarc.targets(deep)
      assert length(Dmarc.targets(deep)) == 8
    end

    test "CH-36: under a psd=y record the organizational domain is one label below", ctx do
      zone(ctx, %{
        {:txt, "_dmarc.sender.example"} => {:error, :nxdomain},
        {:txt, "_dmarc.example"} => [["v=DMARC1; p=none; psd=y"]]
      })

      assert Dmarc.org_domain("a.tx.sender.example", FakeResolver) == "sender.example"

      assert %{name: "example", policy: "none", org_domain: "sender.example"} =
               Dmarc.discover("tx.sender.example", FakeResolver)
    end

    test "CH-36: a subdomain takes sp from its organizational domain's record", ctx do
      zone(ctx, %{{:txt, "_dmarc.sender.example"} => [["v=DMARC1; p=reject; sp=quarantine"]]})
      assert %{policy: "quarantine"} = Dmarc.discover("tx.sender.example", FakeResolver)
      assert %{policy: "reject"} = Dmarc.discover("sender.example", FakeResolver)
    end

    test "CH-36: legacy tags, testing mode, np and alignment are reported", ctx do
      zone(ctx, %{{:txt, "_dmarc.sender.example"} => [["v=DMARC1; p=none; pct=50; t=y"]]})
      findings = "tx.sender.example" |> Dmarc.discover(FakeResolver) |> Dmarc.findings()

      assert {:warning, :dmarc_legacy_tags} in findings
      assert {:warning, :dmarc_testing} in findings
      assert {:suggestion, :dmarc_ramp_with_testing} in findings
      assert {:suggestion, :dmarc_np_reject} in findings
      assert {:suggestion, :dmarc_strict_alignment} in findings
    end

    test "CH-36: no record anywhere is dmarc_missing, and two records at one name count as none",
         ctx do
      zone(ctx, %{{:txt, "_dmarc.sender.example"} => {:error, :nxdomain}})
      assert Dmarc.discover("tx.sender.example", FakeResolver) == nil
      assert Dmarc.findings(nil) == [{:error, :dmarc_missing}]

      doubled = [["v=DMARC1; p=none"], ["v=DMARC1; p=reject"]]
      zone(ctx, %{{:txt, "_dmarc.sender.example"} => doubled})
      assert Dmarc.discover("tx.sender.example", FakeResolver) == nil
    end
  end
end
