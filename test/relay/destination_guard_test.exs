defmodule Relay.DestinationGuardTest do
  use Relay.DataCase, async: true

  alias Relay.Channels.Live.Destination, as: Step
  alias Relay.DestinationGuard
  alias Relay.Repo
  alias RelayTest.OutboxEvents
  alias RelayTest.TenantFixture

  @home %{tr: "+90555", eu: "+49151", us: "+1212"}
  @country %{tr: "TR", eu: "DE", us: "US"}
  @abroad "+447911123456"

  setup do
    tenant = TenantFixture.tenant!()
    %{scope: tenant.live, region: tenant.attrs.region}
  end

  defp number(region, block, last),
    do: Map.fetch!(@home, region) <> block <> String.pad_leading(Integer.to_string(last), 3, "0")

  defp block(region, block), do: Map.fetch!(@home, region) <> block

  defp digits("+" <> digits), do: digits

  defp counter do
    fn _scope, key, _window_ms, :incr, by ->
      count = Process.get({:count, key}, 0) + by
      Process.put({:count, key}, count)
      {:ok, count}
    end
  end

  defp counted(key), do: Process.get({:count, key}, 0)

  defp preload(key, count), do: Process.put({:count, key}, count)

  defp admit(scope, number, opts \\ []) do
    request = %{number: number, number_key: "k" <> digits(number)}
    request = Map.merge(request, Map.new(Keyword.take(opts, [:count?])))
    DestinationGuard.admit(scope, request, counter: Keyword.get(opts, :counter, counter()))
  end

  defp stops(scope, state \\ nil) do
    {:ok, rows} = DestinationGuard.list_stops(scope, state, nil, 50)
    rows
  end

  defp audit(scope, action) do
    now = DateTime.utc_now()
    actor = TenantFixture.actor()

    {:ok, rows} =
      Repo.in_scope(scope, fn _status ->
        Repo.call!(
          "relay_fn.audit_query",
          [DateTime.add(now, -3_600), DateTime.add(now, 3_600), action, nil, 1_000] ++
            [TenantFixture.digest() | Relay.Actor.params(actor)]
        )
      end)

    Enum.reject(rows, &(&1["actor_ref"] == "relay-test" and &1["action"] != action))
  end

  defp allow!(scope, countries) do
    change = %{
      key: "sms.security.allowed_countries",
      value: countries,
      expected_version: nil,
      record_digest: TenantFixture.digest()
    }

    {:ok, _result} = Relay.Tenancy.put_setting(scope, change, TenantFixture.actor())
  end

  defp lift(scope, id, reason) do
    Repo.in_scope(scope, fn _status ->
      DestinationGuard.lift(id, reason, TenantFixture.digest(), TenantFixture.actor())
    end)
  end

  defp stop!(scope, region, block) do
    DestinationGuard.stop(scope, %{
      kind: :prefix,
      value: block(region, block),
      country: Map.fetch!(@country, region),
      rule_id: "destination.pumping_prefix",
      detail: %{"current" => 60, "baseline" => 60, "threshold" => 60, "window" => "PT10M"}
    })
  end

  describe "CH-54 country allow-list" do
    test "CH-54: the default allow-list is the tenant's region", ctx do
      assert admit(ctx.scope, number(ctx.region, "1234", 1)) == :ok
      assert admit(ctx.scope, @abroad) == {:skip, "destination.country_not_allowed"}
      assert admit(ctx.scope, "+8881234567") == {:skip, "destination.country_not_allowed"}
      assert counted("sms_destination:n:k447911123456") == 0
    end

    test "CH-54: a country the tenant adds is allowed, in its own environment only", ctx do
      allow!(ctx.scope, ["GB"])

      assert admit(ctx.scope, @abroad) == :ok
      assert {:ok, %{allowed_countries: ["GB"]}} = DestinationGuard.allow_list(ctx.scope)

      test = %{ctx.scope | environment: :test}
      assert admit(test, @abroad) == {:skip, "destination.country_not_allowed"}
    end

    test "CH-54: the added countries are at most the contract's count of valid codes" do
      cast = &Relay.Tenancy.SettingKeys.cast("sms.security.allowed_countries", &1)

      assert cast.(["GB", "AZ"]) == {:ok, ["AZ", "GB"]}
      assert cast.(nil) == {:ok, nil}
      assert {:error, %Relay.Error{code: :invalid_setting}} = cast.(["gb"])
      assert {:error, %Relay.Error{code: :invalid_setting}} = cast.(["GB", "GB"])
      assert {:error, %Relay.Error{code: :invalid_setting}} = cast.("GB")
    end
  end

  describe "CH-54 rate limits" do
    test "CH-54: a number takes at most the limit in the window and is then not counted to its block",
         ctx do
      number = number(ctx.region, "1234", 1)
      limit = DestinationGuard.limits().number.limit

      for _n <- 1..limit, do: assert(admit(ctx.scope, number) == :ok)

      assert admit(ctx.scope, number) == {:skip, "destination.number_rate_limited"}
      assert admit(ctx.scope, number) == {:skip, "destination.number_rate_limited"}
      assert counted("sms_destination:p:" <> digits(block(ctx.region, "1234"))) == limit
    end

    test "CH-54: a number block takes at most the block limit in the window", ctx do
      limit = DestinationGuard.limits().prefix.limit

      for n <- 1..limit, do: assert(admit(ctx.scope, number(ctx.region, "1234", n)) == :ok)

      over = number(ctx.region, "1234", limit + 1)
      assert admit(ctx.scope, over) == {:skip, "destination.prefix_rate_limited"}
      assert admit(ctx.scope, number(ctx.region, "1235", 1)) == :ok
      assert stops(ctx.scope) == []
    end

    test "CH-54: a retry of a counted delivery checks the list and the stops and counts nothing",
         ctx do
      number = number(ctx.region, "1234", 1)

      assert admit(ctx.scope, number, count?: false) == :ok
      assert counted("sms_destination:n:k" <> digits(number)) == 0

      assert admit(ctx.scope, @abroad, count?: false) ==
               {:skip, "destination.country_not_allowed"}
    end
  end

  describe "CH-54 E-33 pumping detection" do
    test "CH-54, E-33: sends concentrating on a number block stop it with an event and an audit record",
         ctx do
      prefix = block(ctx.region, "1234")
      country = Map.fetch!(@country, ctx.region)
      preload("sms_destination:p:" <> digits(prefix), 59)
      preload("sms_destination:pd:" <> digits(prefix), 59)

      assert admit(ctx.scope, number(ctx.region, "1234", 1)) ==
               {:skip, "destination.prefix_stopped"}

      assert [stop] = stops(ctx.scope, "active")
      assert %{"kind" => "prefix", "value" => ^prefix, "country" => ^country} = stop
      assert stop["rule_id"] == "destination.pumping_prefix"
      assert %{"current" => 60, "baseline" => 60, "threshold" => 60} = stop["detail"]

      assert [event] = OutboxEvents.data(ctx.scope, "sms_destination.stopped")
      assert %{"kind" => "prefix", "value" => ^prefix, "country" => ^country} = event
      assert event["rule_id"] == "destination.pumping_prefix"

      assert [record] = audit(ctx.scope, "sms_destination.stopped")
      assert record["target_id"] == Relay.Id.to_string(stop["id"])
      assert record["actor_ref"] == "relay"

      assert admit(ctx.scope, number(ctx.region, "1234", 2), count?: false) ==
               {:skip, "destination.prefix_stopped"}

      assert admit(ctx.scope, number(ctx.region, "1235", 1)) == :ok
    end

    test "CH-54: a block inside the tenant's own baseline is rate limited, never stopped", ctx do
      prefix = digits(block(ctx.region, "1234"))
      preload("sms_destination:p:" <> prefix, 59)
      preload("sms_destination:pd:" <> prefix, 100_000)

      assert admit(ctx.scope, number(ctx.region, "1234", 1)) ==
               {:skip, "destination.prefix_rate_limited"}

      assert stops(ctx.scope) == []
    end

    test "CH-54: a volume far above the country's baseline stops the country", ctx do
      country = Map.fetch!(@country, ctx.region)
      preload("sms_destination:c:" <> country, 999)
      preload("sms_destination:cd:" <> country, 999)

      assert admit(ctx.scope, number(ctx.region, "1234", 1)) ==
               {:skip, "destination.country_stopped"}

      assert [%{"kind" => "country", "value" => ^country} = stop] = stops(ctx.scope, "active")
      assert stop["rule_id"] == "destination.pumping_country"

      assert admit(ctx.scope, number(ctx.region, "9999", 1)) ==
               {:skip, "destination.country_stopped"}
    end

    test "CH-54: enough stopped blocks of one country stop the country", ctx do
      country = Map.fetch!(@country, ctx.region)
      count = DestinationGuard.limits().pumping.escalation.prefix_stops

      for n <- 1..(count - 1) do
        assert {:ok, {:opened, _id}} = stop!(ctx.scope, ctx.region, "100#{n}")
      end

      refute Enum.any?(stops(ctx.scope), &(&1["kind"] == "country"))
      assert {:ok, {:opened, _id}} = stop!(ctx.scope, ctx.region, "2000")

      assert [%{"value" => ^country, "detail" => detail}] =
               Enum.filter(stops(ctx.scope), &(&1["kind"] == "country"))

      assert detail["prefix_stops"] == count
      assert length(OutboxEvents.data(ctx.scope, "sms_destination.stopped")) == count + 1
      refute DestinationGuard.open?(ctx.scope, country)
    end

    test "CH-54: a stop is opened once", ctx do
      assert {:ok, {:opened, id}} = stop!(ctx.scope, ctx.region, "1234")
      assert {:ok, {:exists, ^id}} = stop!(ctx.scope, ctx.region, "1234")
      assert [_one] = stops(ctx.scope)
    end
  end

  describe "CH-54 lifting a stop" do
    test "CH-54: a stop never ends by itself; lifting is explicit, audited and announced", ctx do
      {:ok, {:opened, id}} = stop!(ctx.scope, ctx.region, "1234")
      number = number(ctx.region, "1234", 1)

      assert admit(ctx.scope, number) == {:skip, "destination.prefix_stopped"}
      assert lift(ctx.scope, id, "the range is ours") == {:ok, :lifted}
      assert lift(ctx.scope, id, "again") == {:ok, :already_lifted}
      assert lift(ctx.scope, Relay.Id.generate(), "none") == {:ok, :not_found}

      assert {:ok, stop} = DestinationGuard.get_stop(ctx.scope, id)
      assert %{"state" => "lifted", "lift_reason" => "the range is ours"} = stop
      assert stop["lifted_by_ref"] == "relay-test"
      assert %DateTime{} = stop["lifted_at"]

      assert [record] = audit(ctx.scope, "sms_destination.released")
      assert record["target_id"] == Relay.Id.to_string(id)
      assert record["reason"] == "the range is ours"

      assert [event] = OutboxEvents.data(ctx.scope, "sms_destination.released")
      assert event["value"] == block(ctx.region, "1234")

      assert admit(ctx.scope, number) == :ok
      assert stops(ctx.scope, "active") == []
      assert [%{"state" => "lifted"}] = stops(ctx.scope, "lifted")
    end

    test "CH-54: the traffic counted before a lift does not stop the destination again", ctx do
      {:ok, {:opened, id}} = stop!(ctx.scope, ctx.region, "1234")
      {:ok, :lifted} = lift(ctx.scope, id, "checked")
      prefix = digits(block(ctx.region, "1234"))
      preload("sms_destination:p:" <> prefix, 59)
      preload("sms_destination:pd:" <> prefix, 59)

      assert {:ok, {:recently_lifted, nil}} = stop!(ctx.scope, ctx.region, "1234")

      assert admit(ctx.scope, number(ctx.region, "1234", 1)) ==
               {:skip, "destination.prefix_rate_limited"}

      assert stops(ctx.scope, "active") == []
    end
  end

  describe "TN-52 INV-43 protections before the security reserve" do
    test "TN-52: every security SMS of a real provider is guarded, whatever quota it was accepted under" do
      security = %{"channel" => "sms", "message_class" => "security"}

      assert Step.guarded?(security, %{"provider" => "netgsm"})
      assert Step.guarded?(Map.put(security, "attempt_count", 3), %{"provider" => "twilio"})
      refute Step.guarded?(security, %{"provider" => "fake"})
      marketing = %{security | "message_class" => "marketing"}
      refute Step.guarded?(marketing, %{"provider" => "netgsm"})
      refute Step.guarded?(%{security | "channel" => "voice"}, %{"provider" => "verimor"})
    end

    test "TN-52, CH-54: the channel step stops a security SMS the protections refuse", ctx do
      _keys = TenantFixture.keys!(ctx.scope)
      delivery = %{"channel" => "sms", "message_class" => "security", "attempt_count" => 0}
      account = %{"provider" => "netgsm"}
      home = number(ctx.region, "1234", 1)

      assert Step.admit(ctx.scope, delivery, account, home) == :ok

      assert Step.admit(ctx.scope, delivery, account, @abroad) ==
               {:skip, "destination.country_not_allowed"}

      assert Step.admit(ctx.scope, delivery, account, "") ==
               {:skip, "destination.country_not_allowed"}

      {:ok, {:opened, _id}} = stop!(ctx.scope, ctx.region, "1234")

      assert Step.admit(ctx.scope, delivery, account, home) ==
               {:skip, "destination.prefix_stopped"}

      assert Step.admit(ctx.scope, delivery, %{"provider" => "fake"}, @abroad) == :ok
      assert Step.admit(ctx.scope, %{delivery | "channel" => "email"}, account, @abroad) == :ok
    end

    test "INV-43: a counter that cannot be read sends nothing and records nothing", ctx do
      down = fn _scope, _key, _window_ms, :incr, _by ->
        {:error, Relay.Error.new(:valkey_unavailable, "down")}
      end

      assert {:error, %Relay.Error{code: :service_unavailable}} =
               admit(ctx.scope, number(ctx.region, "1234", 1), counter: down)

      assert stops(ctx.scope) == []
    end
  end
end
