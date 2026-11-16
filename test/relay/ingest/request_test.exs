defmodule Relay.Ingest.RequestTest do
  use ExUnit.Case, async: true

  @now ~U[2026-11-01 10:00:00Z]
  @steps [
    %{key: "email_step", channel: "email", template: "t"},
    %{key: "sms_step", channel: "sms", template: "t"}
  ]

  defp check(body, class \\ "transactional", environment \\ :live) do
    Relay.Ingest.check_request(
      Map.merge(%{"workflow" => "w", "to" => ["u"]}, body),
      %{message_class: class, steps: @steps, environment: environment, now: @now}
    )
  end

  describe "API-20 API-22 API-24 field rules" do
    test "API-21: targets are classified as plain, inbox-only and explicit upsert" do
      to = ["a", %{"id" => "b"}, %{"id" => "c", "email" => "c@x.io"}]
      {:ok, request} = check(%{"to" => to})

      assert request.targets == [
               {:require, "a"},
               {:inbox_only, "b"},
               {:implicit, "c", %{"email" => "c@x.io"}}
             ]
    end

    test "API-22: marketing is clamped to normal with a warning" do
      {:ok, request} = check(%{"priority" => "high"}, "marketing")
      assert request.priority == "normal"
      assert [%{"code" => "priority_clamped"}] = request.warnings
      assert {:ok, %{priority: "high", warnings: []}} = check(%{"priority" => "high"})
    end

    test "API-20: channels only narrow the workflow's steps" do
      {:ok, request} = check(%{"channels" => ["sms", "push"]})
      assert Enum.map(request.steps, & &1.channel) == ["sms"]
    end

    test "API-24: otp_oob skips the email step and email_verification keeps only email" do
      expires = "2026-11-01T11:00:00Z"

      {:ok, otp} = check(%{"security_subtype" => "otp_oob", "expires_at" => expires}, "security")
      assert [%{channel: "email", skip: {_, _}}, %{channel: "sms", skip: nil}] = otp.steps

      {:ok, verify} =
        check(%{"security_subtype" => "email_verification", "expires_at" => expires}, "security")

      assert [%{channel: "email", skip: nil}, %{channel: "sms", skip: {_, _}}] = verify.steps
    end

    test "IN-55: a security subtype with an inbox step is refused at acceptance" do
      expires = "2026-11-01T11:00:00Z"
      steps = [%{key: "in_app_step", channel: "in_app", template: "t"} | @steps]
      context = %{message_class: "security", steps: steps, environment: :live, now: @now}

      for subtype <- ["otp_oob", "email_verification"] do
        body = %{"workflow" => "w", "to" => ["u"], "security_subtype" => subtype}
        body = Map.put(body, "expires_at", expires)

        assert {:error, %Relay.Error{details: %{errors: errors}}} =
                 Relay.Ingest.check_request(body, context)

        assert [%{pointer: "/security_subtype", code: "conflict"}] = errors

        narrowed = Map.put(body, "channels", ["sms"])
        assert {:ok, _request} = Relay.Ingest.check_request(narrowed, context)
      end

      plain = %{"workflow" => "w", "to" => ["u"]}
      assert {:ok, _request} = Relay.Ingest.check_request(plain, context)
    end

    test "API-20: send_at is in the future and at most 90 days ahead; expires_at follows it" do
      assert {:ok, _} = check(%{"send_at" => "2026-12-01T10:00:00Z"})

      for at <- ["2026-10-31T10:00:00Z", "2027-03-01T10:00:00Z"] do
        assert {:error, %Relay.Error{code: :validation_failed}} = check(%{"send_at" => at})
      end

      times = %{"send_at" => "2026-11-02T10:00:00Z", "expires_at" => "2026-11-01T12:00:00Z"}

      assert {:error, %Relay.Error{details: %{errors: [%{pointer: "/expires_at"}]}}} =
               check(times)
    end

    test "API-62: a per-request send mode is refused in live and kept in test" do
      assert {:error, %Relay.Error{code: :auth_environment_mismatch}} =
               check(%{"send_mode" => "off"})

      assert {:ok, %{send_mode: "off"}} = check(%{"send_mode" => "off"}, "transactional", :test)
    end

    test "API-23: the overrides are kept for the route checks of the send operation" do
      overrides = %{"email" => %{"from" => "a@b.io", "provider" => "smtp"}}
      assert {:ok, %{overrides: ^overrides}} = check(%{"overrides" => overrides})
    end
  end

  describe "E-83 CH-65 interruption and links" do
    test "E-83, CH-65: the sender's interruption and links are kept as sent" do
      links = [%{"rel" => "primary", "href" => "https://example.com/o/1", "title" => "Order"}]

      assert {:ok, %{interruption: "critical", links: ^links}} =
               check(%{"interruption" => "critical", "links" => links})

      assert {:ok, %{interruption: nil, links: nil}} = check(%{})
    end

    test "E-83: a link that is not an absolute https URI is link_scheme_not_allowed" do
      for href <- ["http://example.com/o/1", "myapp://orders/1", "/orders/1", "https:///o"] do
        primary = %{"rel" => "primary", "href" => "https://example.com/"}
        links = [primary, %{"rel" => "b", "href" => href}]

        assert {:error, %Relay.Error{code: :link_scheme_not_allowed, details: details}} =
                 check(%{"links" => links})

        assert [%{pointer: "/links/1/href"}] = details.errors
      end
    end

    test "E-83: a rel is unique in the request" do
      link = %{"rel" => "primary", "href" => "https://example.com/o/1"}

      assert {:error, %Relay.Error{code: :validation_failed, details: details}} =
               check(%{"links" => [link, link]})

      assert [%{pointer: "/links/1/rel", code: "conflict"}] = details.errors
    end
  end

  describe "E-83 item and correlation_id" do
    test "E-83: the sender's item and correlation_id are kept as sent" do
      digest = "sha256:" <> String.duplicate("a", 64)
      item = %{"ref" => "order-1", "version" => "3", "digest" => digest}

      assert {:ok, %{item: ^item, correlation_id: "work-42"}} =
               check(%{"item" => item, "correlation_id" => "work-42"})

      assert {:ok, %{item: nil, correlation_id: nil}} = check(%{})
    end
  end
end
