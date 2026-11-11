defmodule Relay.DeliveryWindowsTest do
  use ExUnit.Case, async: true

  alias Relay.DeliveryWindows

  @hour 3_600_000
  @day 24 * @hour

  defp bundled do
    [:code.priv_dir(:relay), "datasets", "delivery_windows", "v1.json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end

  defp row(channel, provider, short, long),
    do: %{"channel" => channel, "provider" => provider, "short_ms" => short, "long_ms" => long}

  describe "DS-19 the bundled default windows" do
    test "DS-19, DS-51: SMS, email, WhatsApp and voice carry the default windows" do
      assert DeliveryWindows.resolve(bundled(), nil) == [
               row("email", nil, 24 * @hour, 72 * @hour),
               row("sms", nil, 6 * @hour, 72 * @hour),
               row("voice", nil, @hour, 24 * @hour),
               row("whatsapp", nil, 36 * @hour, 7 * @day)
             ]

      assert DeliveryWindows.validate(bundled()) == :ok
    end

    test "DS-13: push, Web Push, in-app and webhook have no window" do
      windows = DeliveryWindows.resolve(bundled(), nil)

      for channel <- ~w(push web_push in_app webhook slack) do
        refute channel in DeliveryWindows.channels()
        assert DeliveryWindows.window(windows, channel, nil) == nil
      end
    end
  end

  describe "DS-18 DS-50 adjusted windows" do
    test "DS-18: a provider row adjusts its channel's window and others keep the default" do
      default = row("sms", nil, 6 * @hour, 72 * @hour)
      netgsm = row("sms", "netgsm", 4 * @hour, 48 * @hour)
      windows = DeliveryWindows.resolve(%{"windows" => [default, netgsm]}, nil)

      assert DeliveryWindows.window(windows, "sms", "netgsm") == netgsm
      assert DeliveryWindows.window(windows, "sms", "twilio") == default
    end

    test "DS-50: a tenant window stays between half and twice the default" do
      tenant = %{
        "windows" => [row("sms", nil, @hour, 30 * @day), row("email", "ses", 100 * @hour, @hour)]
      }

      windows = DeliveryWindows.resolve(bundled(), tenant)

      assert DeliveryWindows.window(windows, "sms", nil) ==
               row("sms", nil, 3 * @hour, 144 * @hour)

      assert DeliveryWindows.window(windows, "email", "ses") ==
               row("email", "ses", 48 * @hour, 48 * @hour)
    end

    test "DS-50: the short window is at least 15 minutes and the long one at most 14 days" do
      default = row("voice", nil, 20 * 60_000, 10 * @day)
      wide = row("voice", "x", 900_000, 20 * @day)

      assert DeliveryWindows.resolve(%{"windows" => [default, wide]}, nil) == [
               default,
               %{wide | "long_ms" => 14 * @day}
             ]
    end

    test "DS-50: a channel without an installation default has no window" do
      tenant = %{"windows" => [row("whatsapp", nil, 36 * @hour, 7 * @day)]}
      installation = %{"windows" => [row("sms", nil, 6 * @hour, 72 * @hour)]}

      assert DeliveryWindows.resolve(installation, tenant) == [
               row("sms", nil, 6 * @hour, 72 * @hour)
             ]
    end

    test "DS-50: a repeated row or a long window shorter than the short one is refused" do
      once = row("sms", nil, @hour, 2 * @hour)
      twice = %{"windows" => [once, %{once | "long_ms" => 3 * @hour}]}
      inverted = %{"windows" => [row("sms", nil, 3 * @hour, 2 * @hour)]}

      assert {:error, %Relay.Error{details: %{rule: :unique_windows}}} =
               DeliveryWindows.validate(twice)

      assert {:error, %Relay.Error{details: %{rule: :long_not_shorter}}} =
               DeliveryWindows.validate(inverted)
    end
  end

  describe "INV-5 window stages" do
    test "INV-5: unknown_pending after the short window, unknown after the long one" do
      window = row("sms", nil, 6 * @hour, 72 * @hour)
      accepted = ~U[2026-12-01 00:00:00Z]
      at = &DateTime.add(accepted, &1, :millisecond)

      assert DeliveryWindows.stage(window, accepted, at.(6 * @hour - 1)) == 0
      assert DeliveryWindows.stage(window, accepted, at.(6 * @hour)) == 1
      assert DeliveryWindows.stage(window, accepted, at.(72 * @hour - 1)) == 1
      assert DeliveryWindows.stage(window, accepted, at.(72 * @hour)) == 2
    end
  end
end
