defmodule Relay.RuleDictionaryTest do
  use ExUnit.Case, async: true

  alias Relay.Datasets.Package
  alias Relay.RuleDictionary

  @events "contracts/asyncapi/events.yaml"
  @settings ~w(send_mode.category. send_mode.channel. email.tracking.)
  @double ~r/"([a-z][a-z0-9_]*\.(?:[a-z0-9_.:-]|#\{[^}"]*\})*)"(\s*(?:<>|\|\|))?/
  @single ~r/'([a-z][a-z0-9_]*\.[a-z0-9_.:-]*)'(\s*(?:<>|\|\|))?/
  @file_name ~r/\.(ya?ml|json|exs?|sql|md|txt)$/

  @stage_four ~w(suppression.address consent.missing consent.revoked consent.expired
                 channel.no_address channel.address_disabled channel.no_permission
                 channel_policy.otp_channel_forbidden channel_policy.email_verification_only
                 scope.mismatch tenant.suspended preference.tenant_category
                 preference.category_channel preference.channel preference.workflow
                 preference.scope_key preference.schedule preference.category_default
                 quiet_hours.deferred schedule.deferred dnd.deferred
                 tenant_timezone_window.deferred frequency.dropped frequency.deferred
                 frequency.digest frequency.inbox_only expiry.expires_at expiry.no_window)

  @stage_five ~w(template.variant_missing template.locale_missing template.not_published
                 template.archived)

  @existing ~w(killswitch.off killswitch.canary killswitch.paused_until killswitch.state_unknown
               killswitch.resume killswitch.paused_expired killswitch.bulk_cancel
               load_shed.l0_alarm load_shed.l1 load_shed.l2 load_shed.l3 admission.breaker_open
               channel_parameters.missing subscriber.suspended send_mode.off cancel.request
               quality.alarm retry.policy retry.permanent retry.max_attempts retry.budget_denied
               retry.expires_at retry.uncertain rate_limit.backend_unavailable)

  defp versions do
    "priv/datasets/rule_dictionary"
    |> File.ls!()
    |> Enum.flat_map(fn file ->
      case Regex.run(~r/\Av([1-9][0-9]*)\.json\z/, file) do
        [_, n] -> [{String.to_integer(n), Path.join("priv/datasets/rule_dictionary", file)}]
        nil -> []
      end
    end)
    |> Enum.sort()
    |> Enum.map(fn {_n, path} -> path |> File.read!() |> Jason.decode!() end)
  end

  defp dictionary, do: RuleDictionary.index(RuleDictionary.bundled())

  defp event_names, do: MapSet.new(YamlElixir.read_from_file!(@events)["x-relay-event-names"])

  defp literals(path) do
    source = File.read!(path)
    patterns = if String.ends_with?(path, ".exs"), do: [@double, @single], else: [@double]

    for pattern <- patterns, [_ | groups] <- Regex.scan(pattern, source) do
      case groups do
        [literal] -> {literal, false}
        [literal, concat] -> {literal, concat != ""}
      end
    end
  end

  defp accounted?(literal, concat?, ids, names) do
    static = literal |> String.split("\#{", parts: 2) |> hd()
    open? = concat? or String.contains?(literal, "\#{")
    pool = MapSet.union(ids, names)

    cond do
      String.contains?(static, ":") -> MapSet.member?(ids, RuleDictionary.base(static))
      MapSet.member?(pool, static) -> true
      open? -> Enum.any?(pool, &String.starts_with?(&1, static))
      true -> false
    end
  end

  describe "DS-47 rule dictionary" do
    test "DS-47: every bundled version is valid and its identifiers are of the dictionary form" do
      assert {:ok, datasets} = Package.read(Package.root())
      assert Enum.any?(datasets, &(&1.name == "rule_dictionary"))

      for version <- versions() do
        assert RuleDictionary.validate(version) == :ok
      end
    end

    test "DS-47 (2): a rule is never removed from a later version, only deprecated" do
      versions()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [previous, next] -> assert RuleDictionary.keeps(previous, next) == :ok end)

      previous = %{"rules" => [%{"id" => "scope.mismatch"}, %{"id" => "retry.policy"}]}
      next = %{"rules" => [%{"id" => "scope.mismatch"}]}

      assert {:error, %Relay.Error{details: %{rules: ["retry.policy"]}}} =
               RuleDictionary.keeps(previous, next)
    end

    test "DS-47 (5): the initial entries of the existing rules and of stage four are present" do
      ids = Map.keys(dictionary())

      for id <- @stage_four ++ @existing, do: assert(id in ids, id)
    end

    test "TP-51: the stage five template rules are present and none is a render failure" do
      dictionary = dictionary()

      for id <- @stage_five do
        assert %{"kind" => "gate", "outcome" => "skip"} = dictionary[id], id
      end

      refute Enum.any?(Map.keys(dictionary), &String.starts_with?(&1, "template.render"))
    end

    test "DS-47 (3): every entry names its reason, kind, decision and both explanations" do
      for {id, entry} <- dictionary() do
        assert entry["kind"] in ~w(gate filter shaper terminal admission), id
        assert is_binary(entry["reason"]) and is_binary(entry["decision"]), id
        assert entry["decision"] =~ ~r/^[A-Z]+-[0-9]+$/, id
        assert is_list(entry["detail"]), id
        assert entry["description"]["en"] != "" and entry["description"]["tr"] != "", id
      end
    end

    test "DS-47 (1): spec decision identifiers are never rule identifiers" do
      refute RuleDictionary.rule_id?("TN-5")
      refute RuleDictionary.rule_id?("quiet_hours")
      assert RuleDictionary.rule_id?("scope.mismatch")
      assert RuleDictionary.rule_id?("killswitch.bulk_cancel:ksw_01j9zq3k4m5n6p7q8r9s0t1v2w")
      refute RuleDictionary.rule_id?(String.duplicate("a.", 70))
    end

    test "DS-47 (1): a reference after the colon is ignored by the lookup" do
      assert {:ok, %{"outcome" => "cancel"}} =
               RuleDictionary.lookup(dictionary(), "cancel.request:0199f1c6-0000-7000-8000-0000")

      assert {:error, %Relay.Error{code: :unknown_rule}} =
               RuleDictionary.lookup(dictionary(), "nothing.here")
    end

    test "DS-47 (4): every rule_id literal in the code and in SQL is in the dictionary" do
      ids = MapSet.new(Map.keys(dictionary()))
      domains = MapSet.new(ids, &(&1 |> String.split(".") |> hd()))
      names = MapSet.union(event_names(), MapSet.new(@settings))

      files = Path.wildcard("lib/**/*.ex") ++ Path.wildcard("priv/repo/migrations/*.exs")
      assert files != []

      unknown =
        for path <- files,
            {literal, concat?} <- literals(path),
            MapSet.member?(domains, literal |> String.split(".") |> hd()),
            not Regex.match?(@file_name, literal),
            not accounted?(literal, concat?, ids, names),
            do: {path, literal}

      assert unknown == []
    end
  end
end
