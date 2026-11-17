defmodule Relay.ComplianceTest do
  use ExUnit.Case, async: true

  alias Relay.Compliance
  alias Relay.Datasets.Package
  alias Relay.Templates.Lint.LegalFooter

  @channels ~w(push web_push email sms voice whatsapp slack teams telegram discord in_app webhook)

  defp table, do: elem(Compliance.bundled_table(), 1)

  defp resolve(changes, refusals \\ %{}) do
    query =
      Map.merge(
        %{
          channel: "email",
          class: "marketing",
          recipient_type: "individual",
          platform: nil,
          countries: [],
          fallback: "TR"
        },
        Map.new(changes)
      )

    Compliance.resolve(table(), refusals, query)
  end

  describe "PC-44 the bundled compliance table" do
    test "PC-44: the bundled versions are valid and belong to their data sets" do
      assert {:ok, datasets} = Package.read(Package.root())

      for name <- ["compliance_table", "compliance_settings"] do
        assert %{versions: [%{no: 1} | _]} = Enum.find(datasets, &(&1.name == name)), name
      end

      assert {1, content} = Compliance.bundled_table()
      assert Compliance.validate_table(content) == :ok
      assert Relay.Datasets.consistent("compliance_table", content) == :ok
    end

    test "PC-44, PC-41: a version without the safe default, with a repeated row or a window that ends before it starts is refused" do
      content = table()
      rows = content["country_rows"]

      unsafe = %{content | "country_rows" => Enum.reject(rows, &(&1["country"] == "*"))}

      assert {:error, %Relay.Error{details: %{rule: :safe_default}}} =
               Compliance.validate_table(unsafe)

      twice = %{content | "country_rows" => rows ++ [hd(rows)]}

      assert {:error, %Relay.Error{details: %{rule: :unique_rows}}} =
               Compliance.validate_table(twice)

      inverted =
        Enum.map(rows, fn
          %{"legal_window" => window} = row ->
            %{row | "legal_window" => %{window | "from" => "21:00", "to" => "08:00"}}

          row ->
            row
        end)

      assert {:error, %Relay.Error{details: %{rule: :windows}}} =
               Compliance.validate_table(%{content | "country_rows" => inverted})
    end
  end

  describe "PC-40 country rows" do
    test "PC-40: Turkey asks an individual for explicit opt-in on SMS, e-mail and voice" do
      for channel <- ["sms", "email", "voice"] do
        assert %{required: "explicit_opt_in", accepted: ["explicit_opt_in"]} =
                 resolved = resolve(channel: channel, countries: ["TR"])

        assert resolved.row == "tr.marketing.individual"
        assert resolved.country == "TR"
        assert resolved.default == :locked_off
      end
    end

    test "PC-24, PC-42: a merchant in Turkey needs no prior consent; the exception is a row" do
      for channel <- ["sms", "email", "voice"] do
        resolved = resolve(channel: channel, countries: ["TR"], recipient_type: "merchant")

        assert %{required: "none", row: "tr.marketing.merchant", default: :tenant} = resolved
      end

      row = Enum.find(table()["country_rows"], &(&1["id"] == "tr.marketing.merchant"))
      assert row["iys"] == "rejection"
    end

    test "PC-43: push, in-app and WhatsApp marketing and the informational classes need no consent in Turkey" do
      for channel <- ["push", "web_push", "in_app", "whatsapp"] do
        assert %{required: "none"} = resolve(channel: channel, countries: ["TR"])
      end

      for class <- ["transactional", "operational"], channel <- @channels do
        assert %{required: "none", row: "tr.informational"} =
                 resolve(channel: channel, class: class, countries: ["TR"])
      end
    end

    test "PC-42: the EU accepts soft opt-in from an individual and legitimate interest from a legal person" do
      for country <- ["DE", "FR", "NL"], channel <- ["email", "sms"] do
        individual = resolve(channel: channel, countries: [country])
        assert individual.required == "soft_opt_in"
        assert individual.accepted == ["soft_opt_in", "explicit_opt_in"]
        assert individual.row == "eu.marketing.individual"

        legal = resolve(channel: channel, countries: [country], recipient_type: "merchant")
        assert legal.required == "legitimate_interest"
        assert legal.accepted == ["legitimate_interest", "soft_opt_in", "explicit_opt_in"]
      end
    end

    test "PC-40: the United States rows: opt-out e-mail, written opt-in SMS and voice" do
      assert %{required: "none", row: "us.marketing.email", default: :tenant} =
               resolve(channel: "email", countries: ["US"])

      for channel <- ["sms", "voice"] do
        assert %{required: "explicit_opt_in", row: "us.marketing.sms_voice"} =
                 resolve(channel: channel, countries: ["US"])
      end

      for class <- ["transactional", "security"] do
        resolved = resolve(channel: "sms", class: class, countries: ["US"])
        assert %{required: "explicit_opt_in", default: :tenant} = resolved
        assert resolved.row == "us.sms.transactional_security"
      end

      assert %{required: "none", row: nil} = resolve(channel: "push", countries: ["US"])
    end

    test "PC-41: a country without a row needs explicit opt-in for marketing on every channel" do
      for country <- ["JP", "BR", "CA"], channel <- @channels do
        assert %{required: "explicit_opt_in", row: "other.marketing", default: :locked_off} =
                 resolve(channel: channel, countries: [country])
      end

      assert %{required: "none", row: nil} =
               resolve(channel: "email", class: "transactional", countries: ["JP"])
    end

    test "PC-40: the phone's calling code and the profile country give the countries; the more restrictive row wins" do
      assert Compliance.candidates(table(), "90", nil) == ["TR"]
      assert Compliance.candidates(table(), "1", nil) == ["US", "CA"]
      assert Compliance.candidates(table(), "49", "TR") == ["TR", "DE"]
      assert Compliance.candidates(table(), nil, nil) == []

      mixed = resolve(channel: "email", countries: ["US", "TR"])
      assert %{required: "explicit_opt_in", country: "TR"} = mixed

      shared = resolve(channel: "email", countries: Compliance.candidates(table(), "1", nil))
      assert %{required: "explicit_opt_in", country: "CA", row: "other.marketing"} = shared
    end

    test "PC-40: a recipient without a country is read with the country of the tenant's region" do
      assert Compliance.region_country("tr") == "TR"

      for {region, row} <- [
            {"tr", "tr.marketing.individual"},
            {"eu", "eu.marketing.individual"},
            {"us", "us.marketing.email"}
          ] do
        assert %{row: ^row} = resolve(fallback: Compliance.region_country(region))
      end
    end
  end

  describe "INV-17 tightening" do
    test "INV-17, PC-40: a refusal makes a row stricter" do
      refusals = Compliance.refusals(nil, %{"refusals" => [refusal("EU", ["soft_opt_in"])]})

      assert %{required: "explicit_opt_in", accepted: ["explicit_opt_in"]} =
               resolve([countries: ["DE"]], refusals)

      assert %{required: "soft_opt_in"} = resolve([countries: ["DE"]], %{})

      legal = Compliance.refusals(nil, %{"refusals" => [refusal("DE", ["legitimate_interest"])]})

      assert %{required: "explicit_opt_in", accepted: ["explicit_opt_in"]} =
               resolve([countries: ["DE"], recipient_type: "merchant"], legal)

      assert %{required: "legitimate_interest"} =
               resolve([countries: ["FR"], recipient_type: "merchant"], legal)
    end

    test "INV-17: no refusal loosens a row or touches one that needs no consent" do
      everything = %{
        "refusals" => [
          refusal("TR", ["soft_opt_in", "legitimate_interest"]),
          refusal("US", ["soft_opt_in", "legitimate_interest"])
        ]
      }

      refusals = Compliance.refusals(everything, everything)

      assert %{required: "explicit_opt_in"} = resolve([countries: ["TR"]], refusals)
      assert %{required: "none"} = resolve([countries: ["US"]], refusals)

      assert %{required: "none"} =
               resolve([countries: ["TR"], recipient_type: "merchant"], refusals)
    end

    test "INV-17: only soft opt-in and legitimate interest can be refused, each country once" do
      assert Compliance.check_refusals([refusal("EU", ["soft_opt_in"])]) == []

      assert Compliance.check_refusals([refusal("EU", ["explicit_opt_in"])]) ==
               [{0, "consent_kinds", "not_allowed"}]

      assert Compliance.check_refusals([refusal("EU", ["none"])]) ==
               [{0, "consent_kinds", "not_allowed"}]

      twice = [refusal("DE", ["soft_opt_in"]), refusal("DE", ["legitimate_interest"])]
      assert Compliance.check_refusals(twice) == [{1, "country", "conflict"}]

      assert {:error, %Relay.Error{}} = Compliance.validate_settings(%{"refusals" => twice})
      assert Compliance.validate_settings(%{"refusals" => []}) == :ok
    end

    test "INV-17, PC-47: the settings schema has no field that loosens a row or changes a legal window" do
      schema = "priv/datasets/compliance_settings/schema.json" |> File.read!() |> Jason.decode!()
      refusal = schema["properties"]["refusals"]["items"]

      assert schema["additionalProperties"] == false
      assert Map.keys(schema["properties"]) == ["refusals", "source_ref"]
      assert refusal["additionalProperties"] == false
      assert Map.keys(refusal["properties"]) == ["consent_kinds", "country"]

      assert refusal["properties"]["consent_kinds"]["items"]["enum"] ==
               ["soft_opt_in", "legitimate_interest"]
    end
  end

  describe "PC-54 platform rows" do
    test "PC-54: iOS push and WhatsApp marketing are locked off; Android push and in-app are the tenant's choice" do
      ios = resolve(channel: "push", platform: "ios", countries: ["TR"])
      assert %{default: :locked_off, platform_row: "platform.ios.push", required: "none"} = ios

      whatsapp = resolve(channel: "whatsapp", countries: ["TR"])
      assert %{default: :locked_off, platform_row: "platform.whatsapp"} = whatsapp

      android = resolve(channel: "push", platform: "android", countries: ["TR"])
      assert %{default: :tenant, platform_row: "platform.android.push"} = android

      assert %{default: :tenant, platform_row: "platform.in_app"} =
               resolve(channel: "in_app", countries: ["TR"])

      assert %{default: :tenant, platform_row: nil} =
               resolve(channel: "push", platform: "web", countries: ["TR"])
    end

    test "PC-54: the platform row and the country row apply together and the more restrictive wins" do
      inbox = resolve(channel: "in_app", countries: ["JP"])
      assert %{default: :locked_off, required: "explicit_opt_in"} = inbox
      assert inbox.platform_row == "platform.in_app"

      assert %{default: :locked_off, required: "explicit_opt_in"} =
               resolve(channel: "push", platform: "android", countries: ["JP"])

      assert %{default: :locked_off, required: "none"} =
               resolve(channel: "push", platform: "ios", countries: ["US"])
    end

    test "PC-14: only a marketing cell is locked off by the table" do
      assert %{default: :tenant} =
               resolve(channel: "sms", class: "transactional", countries: ["US"])
    end
  end

  describe "PC-47 legal send window and obligations" do
    test "PC-47: the United States row carries the 08:00–21:00 window for SMS and voice and the zones it is kept in" do
      for channel <- ["sms", "voice"] do
        assert %{legal_windows: [window]} = resolve(channel: channel, countries: ["US"])
        assert window.from == ~T[08:00:00]
        assert window.to == ~T[21:00:00]
        assert "Pacific/Honolulu" in window.zones and "America/New_York" in window.zones
        assert Enum.all?(window.zones, &match?({:ok, _zone}, Relay.TimeZone.new(&1)))
      end

      assert %{legal_windows: [_window]} = resolve(channel: "sms", countries: ["TR", "US"])
      assert %{legal_windows: []} = resolve(channel: "email", countries: ["US"])
      assert %{legal_windows: []} = resolve(channel: "sms", countries: ["TR"])
    end

    test "PC-39: a revocation by SMS or voice in the United States covers both channels" do
      assert Compliance.revocation_scope(table(), "US", "sms") ==
               %{scope: "all_channel", channels: ["sms", "voice"]}

      assert Compliance.revocation_scope(table(), "US", "email") == nil
      assert Compliance.revocation_scope(table(), "TR", "sms") == nil

      assert %{revocation_channels: ["sms", "voice"]} =
               resolve(channel: "sms", class: "security", countries: ["US"])

      assert %{revocation_channels: []} = resolve(channel: "sms", countries: ["TR"])
    end

    test "TP-33: the footer fields of the table are the fields the publish gate asks for" do
      turkey = Compliance.footer(table(), "TR", "email")
      assert turkey -- ["commercial_notice"] == LegalFooter.missing(%{}, %{}, "TR")
      assert Compliance.footer(table(), "US", "email") == LegalFooter.missing(%{}, %{}, "US")
      assert Compliance.footer(table(), "DE", "email") == LegalFooter.missing(%{}, %{}, "DE")
    end
  end

  defp refusal(country, kinds), do: %{"country" => country, "consent_kinds" => kinds}
end
