defmodule RelayWeb.Api.DeliveryWindowsTest do
  use Relay.DataCase, async: false

  alias Relay.Datasets
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @hour 3_600_000

  defp forget,
    do:
      Datasets.Cache.invalidate(
        Datasets.Cache,
        {Datasets.installation_scope(), "delivery_windows"}
      )

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    on_exit(&forget/0)
    tenant = TenantFixture.tenant!()
    %{scope: tenant.live, token: F.token(tenant.live)}
  end

  defp sms(short, long),
    do: %{"channel" => "sms", "provider" => nil, "short_ms" => short, "long_ms" => long}

  defp put(token, windows),
    do: F.request(:put, "/v1/delivery_windows", token, %{"windows" => windows})

  defp in_force(view, channel), do: Enum.find(view["windows"], &(&1["channel"] == channel))

  describe "DS-18 DS-50 the tenant's DLR windows" do
    test "DS-18: the installation defaults are in force until the tenant sets its own", ctx do
      view = F.body(F.request(:get, "/v1/delivery_windows", ctx.token), 200)

      assert %{"object" => "delivery_windows", "version" => nil, "tenant_windows" => []} = view
      assert length(view["windows"]) == 4
      assert %{"short_ms" => 21_600_000, "source" => "installation"} = in_force(view, "sms")
    end

    test "DS-50, DS-46: a tenant version inside the bounds is published and in force", ctx do
      view = F.body(put(ctx.token, [sms(3 * @hour, 144 * @hour)]), 200)

      assert %{"version" => 1, "tenant_windows" => [_own]} = view
      assert %{"short_ms" => 10_800_000, "source" => "tenant"} = in_force(view, "sms")
      assert %{"source" => "installation"} = in_force(view, "email")

      assert {:ok, windows} = Relay.Delivery.WindowSweep.windows(ctx.scope)
      assert %{"long_ms" => 518_400_000} = Relay.DeliveryWindows.window(windows, "sms", nil)

      reset = F.body(put(ctx.token, []), 200)
      assert %{"version" => 2, "tenant_windows" => []} = reset
      assert %{"source" => "installation"} = in_force(reset, "sms")
    end

    test "DS-50: a window outside the bounds or repeated is refused with its pointer", ctx do
      outside = F.body(put(ctx.token, [sms(@hour, 72 * @hour)]), 422)
      assert [%{"pointer" => "/windows/0/short_ms", "code" => "not_allowed"}] = outside["errors"]

      repeated = [sms(6 * @hour, 72 * @hour), sms(5 * @hour, 72 * @hour)]
      twice = F.body(put(ctx.token, repeated), 422)
      assert [%{"pointer" => "/windows/1/provider", "code" => "conflict"}] = twice["errors"]

      email = %{sms(48 * @hour, 36 * @hour) | "channel" => "email"}
      inverted = F.body(put(ctx.token, [email]), 422)
      assert [%{"pointer" => "/windows/0/long_ms", "code" => "conflict"}] = inverted["errors"]

      view = F.body(F.request(:get, "/v1/delivery_windows", ctx.token), 200)
      assert view["version"] == nil
    end
  end
end
