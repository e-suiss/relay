defmodule Relay.Templates.SandboxTest do
  use ExUnit.Case, async: true

  alias Relay.Templates.Context
  alias Relay.Templates.Engine
  alias Relay.Templates.Sandbox

  @nested "{% for a in xs %}{% for b in xs %}{{ a }}{{ b }}{% endfor %}{% endfor %}"

  defp run(source, data, opts \\ []) do
    channel = Keyword.get(opts, :channel, :sms)
    {:ok, template} = Engine.parse(source)

    {:ok, context} =
      Context.new(channel,
        locale: "tr",
        time_zone: "Europe/Istanbul",
        data: data,
        variables: Keyword.get(opts, :variables, %{})
      )

    Sandbox.run(template, context, channel, Keyword.get(opts, :limits, []))
  end

  describe "TP-7 TP-49 bounded render" do
    test "TP-7: a render returns its output and measures" do
      result = run("Merhaba {{ name }} 👍🏽", %{"name" => "Ayşe"})
      assert {:ok, "Merhaba Ayşe 👍🏽", measures} = result

      assert measures == %{
               characters: 15,
               graphemes: 14,
               bytes: 22,
               blank: false,
               fallbacks: 0,
               fallback_variables: []
             }
    end

    test "TP-7: a render over its time budget is stopped" do
      data = %{"xs" => Enum.to_list(1..3_000)}
      limits = [timeout_ms: 5, max_heap_bytes: 1024 * 1024 * 1024]

      assert run(@nested, data, limits: limits) == {:error, :render_timeout}
    end

    test "TP-49: a render over its heap limit is killed as output_too_large" do
      data = %{"xs" => Enum.to_list(1..3_000)}
      limits = [timeout_ms: 60_000, max_heap_bytes: 1024 * 1024]

      assert run(@nested, data, limits: limits) == {:error, :output_too_large}
    end

    test "TP-7: output over the channel's byte limit is refused, not cut" do
      data = %{"s" => String.duplicate("x", 100)}

      assert run("{{ s }}", data, limits: [max_output_bytes: 99]) == {:error, :output_too_large}
      assert {:ok, _, %{bytes: 100}} = run("{{ s }}", data, limits: [max_output_bytes: 100])
    end

    test "TP-41: a missing required variable stops the render" do
      assert run("Kod {{ code }}", %{}) == {:error, {:missing_variable, "code"}}
    end

    test "TP-14: fallback variables are counted in the measures" do
      variables = %{"name" => %{class: :fallback, default: "Değerli müşterimiz"}}

      assert {:ok, "Merhaba Değerli müşterimiz", %{fallbacks: 1, fallback_variables: ["name"]}} =
               run("Merhaba {{ name }}", %{}, variables: variables)
    end

    test "TP-7: a blank output is measured" do
      assert {:ok, "  ", %{blank: true}} = run("{% if x %}a{% endif %}  ", %{"x" => false})
    end

    test "TP-49: the limits by channel" do
      email = Sandbox.limits(:email)
      sms = Sandbox.limits(:sms)

      assert email.max_heap_bytes == 16 * 1024 * 1024
      assert sms.max_heap_bytes == 4 * 1024 * 1024
      assert Sandbox.limits(:push, timeout_ms: 7).timeout_ms == 7
    end

    test "TP-24: a context built for another channel is refused" do
      {:ok, template} = Engine.parse("{{ x }}")
      {:ok, context} = Context.new(:push, locale: "tr", time_zone: "UTC", data: %{"x" => 1})

      assert_raise ArgumentError, fn -> Sandbox.run(template, context, :sms) end
    end

    test "TP-49: the render process is not linked to the caller" do
      Process.flag(:trap_exit, true)
      data = %{"xs" => Enum.to_list(1..3_000)}

      assert run(@nested, data, limits: [timeout_ms: 5, max_heap_bytes: 1024 * 1024 * 1024]) ==
               {:error, :render_timeout}

      refute_receive {:EXIT, _, _}, 50
    end
  end
end
