defmodule Relay.Channels.ChannelParametersTest do
  use Relay.DataCase, async: false

  alias Relay.ChannelParameters
  alias Relay.Datasets
  alias Relay.Datasets.Package
  alias Relay.Datasets.Schema
  alias RelayTest.DeliveryFixture
  alias RelayTest.TenantFixture

  @dir "priv/datasets/channel_parameters"

  defp content(no), do: Path.join(@dir, "v#{no}.json") |> File.read!() |> Jason.decode!()

  defp schema do
    {:ok, root} =
      Path.join(@dir, "schema.json") |> File.read!() |> Jason.decode!() |> Schema.build()

    root
  end

  defp row(rows, fields), do: Enum.find(rows, &Enum.all?(fields, fn {k, v} -> &1[k] == v end))

  describe "CH-69 data set" do
    test "CH-69: every bundled version matches the schema and the consistency rules" do
      for no <- [1, 2] do
        assert :ok = Schema.validate(schema(), content(no))
        assert :ok = ChannelParameters.validate(content(no))
      end

      assert {:ok, datasets} = Package.read(Package.root())

      assert %{versions: [%{no: 1}, %{no: 2}]} =
               Enum.find(datasets, &(&1.name == "channel_parameters"))
    end

    test "CH-69: the schema refuses unknown fields, a missing base for exponential backoff and a lease without a block" do
      base = content(1)
      [first | rest] = base["backoff"]

      for broken <- [
            Map.put(base, "extra", 1),
            Map.put(base, "backoff", [Map.put(first, "base_ms", nil) | rest]),
            Map.put(base, "backoff", [Map.put(first, "provider", "APNs") | rest]),
            Map.update!(base, "credit_leases", fn [l | ls] ->
              [%{l | "allowed" => true, "block_size" => nil} | ls]
            end),
            Map.update!(base, "lane_ceilings", &tl/1)
          ] do
        assert {:error, %Relay.Error{code: :invalid_content}} = Schema.validate(schema(), broken)
      end
    end

    test "CH-69: the consistency rules refuse duplicate keys, a bad lane ladder, a missing common row, an unweighted class and a lease for SMS" do
      base = content(1)
      [first | _] = base["backoff"]

      cases = [
        unique_backoff: Map.update!(base, "backoff", &[first | &1]),
        lane_ceilings:
          Map.update!(base, "lane_ceilings", fn rows ->
            Enum.map(rows, &if(&1["lane"] == "l3", do: %{&1 | "ceiling_bp" => 9900}, else: &1))
          end),
        common_breaker:
          Map.update!(base, "breakers", &Enum.reject(&1, fn r -> r["channel"] == nil end)),
        every_class_weighted:
          Map.update!(
            base,
            "failure_weights",
            &Enum.reject(&1, fn r -> r["failure_class"] == "auth" end)
          ),
        common_retry_budget:
          Map.put(base, "retry_budgets", [%{hd(base["retry_budgets"]) | "channel" => "sms"}]),
        credit_leases:
          Map.update!(base, "credit_leases", fn rows ->
            Enum.map(
              rows,
              &if(&1["channel"] == "sms",
                do: %{&1 | "allowed" => true, "block_size" => 5},
                else: &1
              )
            )
          end),
        backoff_cap: Map.put(base, "backoff", [%{first | "cap_ms" => first["base_ms"] - 1}])
      ]

      for {rule, broken} <- cases do
        assert {:error, %Relay.Error{code: :invalid_content, details: %{rule: ^rule}}} =
                 ChannelParameters.validate(broken),
               inspect(rule)
      end
    end

    test "CH-16, T-25: the breaker rows are the channel table values, never code constants" do
      rows = content(1)["breakers"]
      common = row(rows, %{"channel" => nil, "provider" => nil})

      assert Map.take(
               common,
               ~w(window_ms min_throughput failure_ratio_bp open_ms open_jitter_bp half_open_probes half_open_successes p99_latency_ms)
             ) ==
               %{
                 "window_ms" => 30_000,
                 "min_throughput" => 20,
                 "failure_ratio_bp" => 5000,
                 "open_ms" => 30_000,
                 "open_jitter_bp" => 3000,
                 "half_open_probes" => 3,
                 "half_open_successes" => 3,
                 "p99_latency_ms" => nil
               }

      expected = [
        {"push", "apns", 30_000, 3000, 20_000},
        {"push", "fcm", 30_000, 5000, 60_000},
        {"email", nil, 60_000, 4000, 600_000},
        {"whatsapp", nil, 60_000, 5000, 120_000},
        {"sms", nil, 60_000, 5000, 120_000}
      ]

      for {channel, provider, window, ratio, open} <- expected do
        assert %{"window_ms" => ^window, "failure_ratio_bp" => ^ratio, "open_ms" => ^open} =
                 row(rows, %{"channel" => channel, "provider" => provider})
      end
    end

    test "CH-69, T-27, T-33, T-91: retry budget, lane ceilings and failure weights carry the policy defaults" do
      v1 = content(1)
      v2 = content(2)

      assert [
               %{
                 "channel" => nil,
                 "window_ms" => 60_000,
                 "max_ratio_bp" => 1000,
                 "min_retries" => nil
               }
             ] =
               v1["retry_budgets"]

      assert [%{"min_retries" => 10}] = v2["retry_budgets"]

      assert Map.new(v1["lane_ceilings"], &{&1["lane"], &1["ceiling_bp"]}) ==
               %{"l0" => 10_000, "l1" => 9500, "l2" => 8000, "l3" => 6000}

      weights =
        Map.new(
          v1["failure_weights"],
          &{{&1["failure_class"], &1["condition"]}, {&1["weight_milli"], &1["level"]}}
        )

      assert weights[{"sender_config", nil}] == {5000, "tenant_provider"}
      assert weights[{"auth", nil}] == {5000, "tenant_provider"}
      assert weights[{"quota", nil}] == {500, "tenant_provider"}
      assert weights[{"permanent_target", nil}] == {0, "provider"}
      assert Enum.all?(v1["credit_leases"], &(&1["allowed"] == false))
    end
  end

  describe "CH-70 lookups" do
    setup do: %{p: DeliveryFixture.parameters(1)}

    test "CH-70: the most specific backoff row wins and carries the version", %{p: p} do
      assert {:ok, %{"base_ms" => 1_800_000, "cap_ms" => 7_200_000, "max_attempts" => 5}, id} =
               ChannelParameters.backoff(
                 p,
                 :push,
                 "apns",
                 :transient,
                 :server_error,
                 :transactional
               )

      assert id == p.version_id

      assert {:ok, %{"base_ms" => 2000, "cap_ms" => 60_000}, _} =
               ChannelParameters.backoff(p, :push, "apns", :transient, :rate_limited, nil)

      assert {:ok, %{"mode" => "retry_after", "default_retry_after_ms" => 60_000}, _} =
               ChannelParameters.backoff(p, :push, "fcm", :transient, :rate_limited, nil)

      assert {:ok, %{"base_ms" => 1_200_000}, _} =
               ChannelParameters.backoff(p, :email, "ses", :transient, :rate_limited, nil)
    end

    test "CH-70: a security message uses the security row on every channel", %{p: p} do
      for channel <- ~w(push email sms whatsapp voice in_app) do
        assert {:ok, %{"base_ms" => 1000, "cap_ms" => 15_000, "max_attempts" => 3}, _} =
                 ChannelParameters.backoff(
                   p,
                   channel,
                   "any",
                   :transient,
                   :server_error,
                   :security
                 )
      end
    end

    test "CH-70: a failure without a matching row is missing", %{p: p} do
      assert {:error, :missing} =
               ChannelParameters.backoff(p, :sms, nil, :transient, :server_error, nil)

      assert {:error, :missing} = ChannelParameters.backoff(p, :push, "apns", :quota, nil, nil)
      assert {:error, :missing} = ChannelParameters.backoff(p, :email, nil, :auth, nil, nil)
    end

    test "CH-70: on equal specificity the row whose first key field comes earlier wins" do
      rows = [
        backoff(%{"provider" => "x", "base_ms" => 1}),
        backoff(%{"channel" => "push", "base_ms" => 2}),
        backoff(%{"failure_class" => "transient", "condition" => "timeout", "base_ms" => 3}),
        backoff(%{"channel" => "push", "condition" => "timeout", "base_ms" => 4})
      ]

      p = %ChannelParameters{version_id: Relay.Id.generate(), backoff: rows}

      assert {:ok, %{"base_ms" => 4}, _} =
               ChannelParameters.backoff(p, :push, "x", :transient, :timeout, nil)

      assert {:ok, %{"base_ms" => 2}, _} =
               ChannelParameters.backoff(p, :push, "x", :transient, :server_error, nil)
    end

    test "T-25, CH-16: breaker, weight, budget, lease and ceiling lookups", %{p: p} do
      assert {:ok, %{"open_ms" => 20_000}, _} = ChannelParameters.breaker(p, :push, "apns")
      assert {:ok, %{"open_ms" => 30_000}, _} = ChannelParameters.breaker(p, :slack, "slack")
      assert {:ok, %{"open_ms" => 600_000}, _} = ChannelParameters.breaker(p, :email, "ses")
      assert ChannelParameters.weight(p, :transient, :timeout) == {1000, :provider}
      assert ChannelParameters.weight(p, :auth, :timeout) == {5000, :tenant_provider}
      assert ChannelParameters.weight(p, :transient, nil) == {1000, :provider}
      assert {:ok, %{"max_ratio_bp" => 1000}, _} = ChannelParameters.retry_budget(p, :sms)
      assert ChannelParameters.credit_lease(p, :sms) == {false, nil}
      assert ChannelParameters.lane_ceiling(p, :l2) == 8000
    end
  end

  describe "CH-69 activation" do
    setup do
      TenantFixture.as_role("relay_worker")
      :ok
    end

    test "CH-69, CH-18: a new version is published and activated with an audit record and is read without a deploy" do
      scope = Datasets.installation_scope()
      actor = TenantFixture.actor()

      changed =
        put_in(content(1), ["retry_budgets"], [
          %{hd(content(1)["retry_budgets"]) | "max_ratio_bp" => 500}
        ])

      changed = Map.put(changed, "source_ref", "test " <> TenantFixture.random())

      assert {:ok, {:published, id, _no}} =
               Datasets.publish(scope, "channel_parameters", changed, actor, source_ref: "test")

      assert {:ok, :activated} =
               Datasets.activate(scope, "channel_parameters", id, :operator, actor)

      assert {:ok, %ChannelParameters{version_id: ^id} = p} = Datasets.channel_parameters()
      assert {:ok, %{"max_ratio_bp" => 500}, ^id} = ChannelParameters.retry_budget(p, :push)

      assert ["dataset.activated", "dataset_version", Relay.Id.to_string(id)] in audit_rows(scope)
    end

    test "CH-69: an inconsistent version is refused before it is published" do
      broken = Map.put(content(1), "breakers", tl(content(1)["breakers"]))

      assert {:error, %Relay.Error{code: :invalid_content, details: %{rule: :common_breaker}}} =
               Datasets.publish(
                 Datasets.installation_scope(),
                 "channel_parameters",
                 broken,
                 TenantFixture.actor(),
                 source_ref: "test"
               )
    end
  end

  defp audit_rows(scope) do
    now = DateTime.utc_now()
    actor = TenantFixture.actor()

    {:ok, rows} =
      Relay.Repo.in_scope(scope, fn _status ->
        Relay.Repo.query!(
          "SELECT action, target_type, target_id FROM relay_fn.audit_query($1, $2, NULL, NULL, 100, $3, $4, $5, $6, $7)",
          [
            DateTime.add(now, -3600),
            DateTime.add(now, 3600),
            TenantFixture.digest(),
            Atom.to_string(actor.kind),
            actor.ref,
            actor.on_behalf_of_ref,
            actor.access_record_ref
          ]
        ).rows
      end)

    rows
  end

  defp backoff(fields) do
    Map.merge(
      %{
        "channel" => nil,
        "provider" => nil,
        "failure_class" => nil,
        "condition" => nil,
        "message_class" => nil,
        "mode" => "exponential",
        "base_ms" => 1,
        "cap_ms" => 100,
        "default_retry_after_ms" => nil,
        "max_attempts" => 3,
        "source" => "test"
      },
      fields
    )
  end
end
