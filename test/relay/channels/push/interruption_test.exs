defmodule Relay.Channels.Push.InterruptionTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.CriticalGrant
  alias Relay.Channels.Push.Interruption

  defmodule Permit do
    @moduledoc false
    @behaviour CriticalGrant
    @impl CriticalGrant
    def evaluate(_query), do: {:ok, :permit}
  end

  defmodule Deny do
    @moduledoc false
    @behaviour CriticalGrant
    @impl CriticalGrant
    def evaluate(_query), do: {:ok, :deny}
  end

  defmodule Down do
    @moduledoc false
    @behaviour CriticalGrant
    @impl CriticalGrant
    def evaluate(_query), do: {:error, Relay.Error.new(:access_unavailable, "down")}
  end

  defmodule Crash do
    @moduledoc false
    @behaviour CriticalGrant
    @impl CriticalGrant
    def evaluate(_query), do: raise("boom")
  end

  @ceilings %{
    security: :time_sensitive,
    action_required: :time_sensitive,
    transactional: :active,
    operational: :active,
    social: :active,
    marketing: :passive,
    system: nil
  }

  defp input(class, requested, extra \\ %{}) do
    ceiling = Map.fetch!(@ceilings, class)
    base = %{message_class: class, requested: requested, default: ceiling, ceiling: ceiling}
    Map.merge(base, extra)
  end

  defp resolve(class, requested, extra \\ %{}),
    do: Interruption.resolve(input(class, requested, extra))

  @critical %{critical_enabled: true, critical_declared: true}

  describe "CH-65 levels and ceilings" do
    test "CH-65: without a requested level the table level applies" do
      assert %{level: :time_sensitive, reasons: []} = resolve(:security, nil)
      assert %{level: :passive, reasons: []} = resolve(:social, nil, %{default: :passive})
      assert %{level: nil, reasons: []} = resolve(:system, nil)
    end

    test "CH-65: a level above the class ceiling is lowered and recorded" do
      assert %{level: :active, reasons: [:interruption_clamped]} =
               resolve(:operational, :time_sensitive)

      assert %{level: :passive, reasons: [:interruption_clamped]} = resolve(:marketing, :active)
      assert %{level: nil, reasons: [:interruption_clamped]} = resolve(:system, :passive)
    end

    test "E-77: Relay only lowers; a lower requested level is kept" do
      assert %{level: :passive, reasons: []} = resolve(:security, :passive)
      assert %{level: :active, reasons: []} = resolve(:action_required, :active)
    end

    test "CH-65: wire names map to levels and back" do
      for level <- Interruption.levels() do
        assert Interruption.parse(Interruption.name(level)) == {:ok, level}
      end

      assert Interruption.name(:time_sensitive) == "time-sensitive"
      assert Interruption.parse("urgent") == :error
    end

    test "CH-65 (3): Web Push urgency follows the level, never above the table" do
      assert Interruption.web_push_urgency(:passive, :high) == :low
      assert Interruption.web_push_urgency(:active, :high) == :normal
      assert Interruption.web_push_urgency(:time_sensitive, :high) == :high
      assert Interruption.web_push_urgency(:critical, :high) == :high
      assert Interruption.web_push_urgency(:active, :low) == :low
      assert Interruption.web_push_urgency(nil, :low) == nil
      assert Interruption.web_push_urgency(:active, nil) == nil
    end

    test "CH-65 (3): a level the platform does not allow is delivered lower and recorded" do
      extra = Map.merge(@critical, %{grant: :permit, platform_max: :time_sensitive})

      assert %{level: :time_sensitive, reasons: [:interruption_platform_lowered]} =
               resolve(:security, :critical, extra)
    end
  end

  describe "CH-68 personal agent" do
    test "CH-68: the recipient's own agent may send time-sensitive transactional" do
      assert %{level: :time_sensitive, reasons: []} =
               resolve(:transactional, :time_sensitive, %{personal_agent: true})

      assert %{level: :active, reasons: []} =
               resolve(:transactional, nil, %{personal_agent: true})
    end

    test "CH-68: without the condition the ceiling stays active" do
      assert %{level: :active, reasons: [:interruption_clamped]} =
               resolve(:transactional, :time_sensitive)
    end

    test "CH-68: the exception does not extend to other classes or to critical" do
      assert %{level: :active, reasons: [:interruption_clamped]} =
               resolve(:operational, :time_sensitive, %{personal_agent: true})

      assert %{level: :time_sensitive, reasons: [:critical_not_granted]} =
               resolve(:transactional, :critical, %{personal_agent: true})
    end
  end

  describe "CH-66 critical needs the recipient's Grant" do
    test "CH-66: tenant opening, declaration and a permit give critical" do
      assert %{level: :critical, reasons: []} =
               resolve(:security, :critical, Map.put(@critical, :grant, :permit))

      grant = fn -> CriticalGrant.decide(Permit, %{}) end

      assert %{level: :critical, reasons: []} =
               resolve(:security, :critical, Map.put(@critical, :grant, grant))
    end

    test "CH-66: a denial, an outage or a crash delivers at the ceiling (fail-closed)" do
      for module <- [Deny, Down, Crash] do
        grant = fn -> CriticalGrant.decide(module, %{}) end

        assert %{level: :time_sensitive, reasons: [:critical_not_granted]} =
                 resolve(:security, :critical, Map.put(@critical, :grant, grant))
      end

      raising = fn -> raise "boom" end

      assert %{level: :time_sensitive, reasons: [:critical_not_granted]} =
               resolve(:security, :critical, Map.put(@critical, :grant, raising))

      assert %{level: :active, reasons: [:critical_not_granted]} =
               resolve(:social, :critical, Map.put(@critical, :grant, :unavailable))
    end

    test "CH-66: the Grant is not asked without the opening and the declaration" do
      parent = self()
      grant = fn -> send(parent, :asked) && :permit end

      for extra <- [%{critical_enabled: true}, %{critical_declared: true}, %{}] do
        assert %{level: :time_sensitive, reasons: [:critical_not_granted]} =
                 resolve(:security, :critical, Map.put(extra, :grant, grant))
      end

      refute_received :asked
    end

    test "CH-66: the port folds every non-permit answer" do
      assert CriticalGrant.decide(Permit, %{}) == :permit
      assert CriticalGrant.decide(Deny, %{}) == :deny
      assert CriticalGrant.decide(Down, %{}) == :unavailable
      assert CriticalGrant.decide(Crash, %{}) == :unavailable
    end
  end

  describe "CH-67 sensitive" do
    test "CH-67: a sensitive notification is neutral and content-free at every level" do
      for level <- [:passive, :time_sensitive, :critical] do
        extra = Map.merge(@critical, %{grant: :permit, sensitive: true})

        assert %{sensitive: true, lock_screen: :neutral, content_free: true} =
                 resolve(:security, level, extra)
      end

      assert %{lock_screen: :content, content_free: false} = resolve(:security, nil)
    end
  end
end
