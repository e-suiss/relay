defmodule Relay.OtpRulesTest do
  use ExUnit.Case, async: true

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Email.Tracking
  alias Relay.Channels.Push.Content
  alias Relay.Channels.Sms
  alias Relay.Ingest.Request
  alias Relay.Policy.Engine
  alias Relay.Policy.Fixture
  alias Relay.RuleDictionary
  alias Relay.Workflow.ContentDedup
  alias Relay.Workflow.RouteTree

  @lib Path.expand("../../lib", __DIR__)
  @migrations Path.expand("../../priv/repo/migrations", __DIR__)
  @contract Path.expand("../../contracts/openapi", __DIR__)
  @now ~U[2026-11-17 10:00:00Z]
  @steps [
    %{key: "email_step", channel: "email", template: "t"},
    %{key: "sms_step", channel: "sms", template: "t"},
    %{key: "voice_step", channel: "voice", template: "t"}
  ]
  @always [%{days: [1, 2, 3, 4, 5, 6, 7], from: ~T[00:00:00], to: ~T[23:59:00]}]
  @measure &Relay.Templates.sms_measure/3
  @number "+905551112233"
  @code_fields ~w(code otp otp_code passcode secret verification_code verified)
  @sender %{
    "value" => "ACME",
    "country" => "TR",
    "sms_type" => "alphanumeric",
    "registration" => %{"iys_brand_code" => "123456"}
  }

  defp check(body, class) do
    body = Map.merge(%{"workflow" => "w", "to" => ["u"]}, body)
    Request.check(body, %{message_class: class, steps: @steps, environment: :live, now: @now})
  end

  defp pointers({:error, %Relay.Error{details: %{errors: errors}}}),
    do: Enum.map(errors, & &1.pointer)

  defp otp(channel, changes \\ []) do
    Engine.evaluate(
      Fixture.snapshot(
        [
          channel: channel,
          notification: [message_class: :security, security_subtype: :otp_oob],
          category: [locked: true]
        ] ++ changes
      )
    )
  end

  defp sources(root, pattern) do
    for file <- Path.wildcard(Path.join(root, pattern)), do: {file, File.read!(file)}
  end

  defp operations do
    for file <- ["server.yaml", "subscriber.yaml", "operator.yaml"],
        document = YamlElixir.read_from_file!(Path.join(@contract, file)),
        {path, methods} <- document["paths"],
        {_method, %{"operationId" => id}} <- methods,
        do: {path, id}
  end

  defp declarations do
    {:ok, content} = ChannelDeclarations.compose()
    ChannelDeclarations.new(content, nil)
  end

  defp declaration(provider) do
    {:ok, declaration} = ChannelDeclarations.declaration(declarations(), provider)
    declaration
  end

  defp preflight(provider, class, content),
    do: Sms.preflight(declaration(provider), @sender, class, @number, content, @measure)

  defp rule(id), do: RuleDictionary.lookup(RuleDictionary.index(RuleDictionary.bundled()), id)

  describe "INV-22 E-34 F-11 Relay does nothing with the code" do
    test "INV-22, F-11: no function generates, issues or verifies a one-time code" do
      definition =
        ~r/\bdefp?\s+(generate|create|issue|verify|check|validate|compare)_(otp|one_time_code|passcode|totp|hotp|verification_code)\b/

      for {file, source} <- sources(@lib, "**/*.ex") do
        refute Regex.match?(definition, source), file
      end

      mix = File.read!(Path.expand("../../mix.exs", __DIR__))
      refute mix =~ ~r/totp|hotp|:pot\b/i
    end

    test "INV-22, E-34: no table has a column for a code or its secret" do
      column =
        ~r/\b(otp|one_time|passcode|verification_code|totp|hotp)[a-z_]*\s+(text|bytea|integer|bigint|smallint|jsonb)\b/i

      for {file, source} <- sources(@migrations, "*.exs") do
        refute Regex.match?(column, source), file
      end
    end

    test "INV-22, E-34: no operation creates, resends or verifies a code" do
      operations = operations()
      assert length(operations) > 100

      for {path, id} <- operations do
        refute id =~ ~r/otp|passcode|one_?time|verification_?code/i, id
        refute path =~ ~r/otp|passcode|verify_code/i, path

        if String.starts_with?(path, ["/v1/events", "/v1/notifications", "/v1/deliveries"]),
          do: refute(id =~ ~r/resend/i, id)
      end
    end

    test "INV-22: a send request has no field for a code, a secret or a verification result" do
      schemas = YamlElixir.read_from_file!(Path.join(@contract, "components/schemas.yaml"))

      for name <- ["EventRequest", "BatchEventRequest"] do
        fields = Map.keys(schemas[name]["properties"])
        assert "security_subtype" in fields
        assert fields -- @code_fields == fields
      end
    end

    test "E-34: sending needs an idempotency key, so a resend is a new request with a new key" do
      server = YamlElixir.read_from_file!(Path.join(@contract, "server.yaml"))

      for path <- ["/v1/events", "/v1/events/batch"] do
        mode = server["paths"][path]["post"]["x-relay-idempotency"]
        assert mode in ["required", "derived"]
      end
    end
  end

  describe "API-24 PC-51 INV-23 WF-18 the subtype's channels" do
    test "API-24, PC-53: a security subtype is refused without expires_at" do
      assert "/expires_at" in pointers(check(%{"security_subtype" => "otp_oob"}, "security"))

      verification = %{"security_subtype" => "email_verification"}
      assert "/expires_at" in pointers(check(verification, "security"))

      body = %{"security_subtype" => "otp_oob", "expires_at" => "2026-11-17T10:05:00Z"}
      assert {:ok, %{security_subtype: "otp_oob"}} = check(body, "security")
    end

    test "API-24: the sender chooses the subtype and only the security class has one" do
      body = %{"security_subtype" => "otp_oob", "expires_at" => "2026-11-17T10:05:00Z"}
      assert "/security_subtype" in pointers(check(body, "transactional"))
    end

    test "PC-51, INV-23: an accepted otp_oob request never sends its e-mail step" do
      body = %{"security_subtype" => "otp_oob", "expires_at" => "2026-11-17T10:05:00Z"}
      {:ok, request} = check(body, "security")

      assert [
               %{channel: "email", skip: {_reason, "channel_policy.otp_channel_forbidden"}},
               %{channel: "sms", skip: nil},
               %{channel: "voice", skip: nil}
             ] = request.steps
    end

    test "INV-23, PC-51: the lattice stops an otp_oob delivery on every channel but SMS, WhatsApp and voice" do
      for channel <- [:email, :push, :web_push, :in_app, :slack, :webhook] do
        assert {:skip, :channel_policy, "channel_policy.otp_channel_forbidden", _detail} =
                 otp(channel)
      end

      for channel <- [:sms, :whatsapp, :voice], do: assert({:send, _info} = otp(channel))
    end

    test "WF-18, INV-23: a fallback of an otp_oob route never falls to e-mail at run time" do
      tree = %{"single" => ["sms", "email", "voice"]}
      failed = %{status: :failed, at: @now, evidence: []}
      facts = %{security_subtype: "otp_oob"}
      state = %{now: @now, leaves: %{"/single/0" => failed}, events: []}

      assert {:ok, plan} = RouteTree.next(tree, facts, state)
      assert [%{channel: "email", rule_id: "channel_policy.otp_channel_forbidden"}] = plan.skip
      assert [%{channel: "voice"}] = plan.open
    end

    test "WF-18: an otp_oob route that names e-mail is refused at publication" do
      assert {:error, [%{code: "not_allowed"}]} =
               RouteTree.validate(%{"single" => ["sms", "email"]}, security_subtype: "otp_oob")

      assert RouteTree.validate(%{"single" => ["sms", "voice"]}, security_subtype: "otp_oob") ==
               :ok
    end
  end

  describe "PC-53 OTP delivery rules" do
    test "PC-53: an OTP passes quiet hours, do not disturb and the availability schedule" do
      quiet = [profile: [quiet_hours: @always, dnd_until: DateTime.add(Fixture.now(), 3_600)]]

      assert {:send, _info} = otp(:sms, quiet)

      operational = [
        channel: :sms,
        notification: [message_class: :operational],
        category: [channel_defaults: %{sms: :on}]
      ]

      assert {:defer, _reason, _rule_id, _until, _detail} =
               Engine.evaluate(Fixture.snapshot(operational ++ quiet))
    end

    test "PC-53: an OTP is never counted against a frequency cap" do
      capped = [
        category: [locked: true, frequency: %{limit: 1, window_ms: 3_600_000, fate: :drop}],
        frequency: %{global: %{count: 99, free_at: nil}, policy: %{count: 99, free_at: nil}}
      ]

      assert {:send, %{frequency: :exempt, counters: []}} = otp(:sms, capped)
    end

    test "PC-53: the security class is never deduplicated by content" do
      assert ContentDedup.window_ms("security", %{"window" => "PT5M"}) == nil
      assert is_integer(ContentDedup.window_ms("operational", nil))
    end

    test "PC-53: an OTP e-mail has no open pixel and no wrapped links, whatever the tenant set" do
      on = %{open_pixel: true, wrap_links: true}
      off = %{open_pixel: false, wrap_links: false}

      for subtype <- [nil, "email_verification", "otp_oob"] do
        message = Map.merge(on, %{class: "security", security_subtype: subtype})
        assert Tracking.plan(message) == off
        assert Tracking.untrackable?("security", subtype)
      end

      assert Tracking.plan(Map.put(on, :class, "marketing")) == on
    end

    test "PC-53: a code is carried neither in a push payload nor in its preview" do
      assert {:error, %Relay.Error{code: :push_content_forbidden, details: %{kind: :otp_code}}} =
               Content.check(%{"title" => "Giriş", "body" => "Kodunuz 123456"})

      assert {:error, %Relay.Error{code: :push_content_forbidden}} =
               Content.check(%{"data" => %{"otp" => "123456"}})

      assert Content.check(%{"title" => "Giris", "body" => "Yeni bir cihazdan giris"}) == :ok
    end
  end

  describe "CH-51 TR route" do
    @link %{"body" => "Kargonuz yolda: https://ornek.example/t/1"}

    test "CH-51: a foreign route with a link in the text stops the send with its own rule" do
      for provider <- ["twilio", "infobip"] do
        assert preflight(provider, "transactional", @link) == {:skip, "channel.foreign_route_url"}
      end

      assert {:ok, %{"kind" => "gate", "outcome" => "skip"}} = rule("channel.foreign_route_url")
    end

    test "CH-51: without a BTK-authorized route a +90 send stops with a rule" do
      assert preflight("twilio", "security", %{"body" => "Kod 1234"}) ==
               {:skip, "channel.tr_route_unauthorized"}

      accounts = [%{"provider" => "twilio"}, %{"provider" => "infobip"}]
      assert Relay.Channels.tr_route(accounts, @number, declarations()) == []

      assert {:ok, %{"kind" => "gate", "outcome" => "skip"}} =
               rule("channel.tr_route_unauthorized")
    end

    test "CH-51: the same text goes through a BTK-authorized provider and abroad through any" do
      assert {:ok, %{sender: @sender}} = preflight("netgsm", "transactional", @link)
      assert Sms.route(declaration("twilio"), "+4915112345678", @link["body"]) == :ok
    end
  end
end
