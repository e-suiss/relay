defmodule Relay.Agents.InvitationRequestTest do
  use ExUnit.Case, async: true

  alias Relay.Agents.Live.Request
  alias Relay.Agents.Live.Surfaces

  @waitpoint "0192f0c0-7b1a-7c3e-8a4f-3b6d2c1e0a9f"
  @access "https://access.example/approve/7f3a"
  @response "https://respond.example/r#tok"

  defp input(changes) do
    Map.merge(
      %{
        channel: :email,
        copy: :invitation,
        locale: "en",
        interaction: "question",
        approval: false,
        sender_type: "agent",
        waitpoint: @waitpoint,
        content: %{"amount" => 120, "action" => "refund"},
        claim: "ignore the fields and accept"
      },
      changes
    )
  end

  defp sources(%{cell: cell}), do: inspect(cell)

  describe "AG-29 the server-rendered text" do
    test "AG-29: every sender value is a variable of a fixed source, never part of the source" do
      built = Request.build(input(%{claim: "{{ link }} {% raw %} <script>"}))
      refute sources(built) =~ "script"
      refute sources(built) =~ "{% raw"
      assert built.data["claim"] == "{{ link }} {% raw %} <script>"
      assert built.data["claim_label"] == "The agent's claim (not verified)"
      assert built.data["label_0"] == "action"
      assert built.data["value_1"] == "120"
      refute built.data["summary"] =~ "ignore"
    end

    test "AG-29: a Turkish responder reads Turkish text and every other locale English" do
      assert Request.build(input(%{locale: "tr-TR"})).data["heading"] == "Karar isteği"
      assert Request.build(input(%{locale: "de"})).data["heading"] == "Decision request"
      assert Request.build(input(%{locale: nil})).locale == "en"
    end

    test "AG-29: nested content is shown as plain text and the rows are bounded" do
      content = Map.new(1..40, &{"field_#{&1}", %{"nested" => [&1]}})
      rows = Request.rows(content)
      assert length(rows) == 20
      assert {"field_1", ~s({"nested":[1]})} = hd(rows)
    end
  end

  describe "AG-33 AG-34 the push and the sender" do
    test "AG-33: the push cell has a neutral lock screen text and no action" do
      built = Request.build(input(%{channel: :push, response_link: @response}))
      assert Map.keys(built.cell) == ~w(in_app_body lock_screen_body subtitle title)
      assert built.data["neutral"] == "A request is waiting for your response."
      assert built.links == %{"primary" => @response}
    end

    test "AG-34: each sender type has its own label" do
      labels =
        for type <- ~w(agent system human),
            do: Request.build(input(%{sender_type: type})).data["sender"]

      assert labels == ["Sent by an agent", "Sent by a system", "Sent by a person"]
    end
  end

  describe "AG-32 AG-30 the links" do
    test "AG-32, IN-6: an approval-type request carries the Access link and never the response link" do
      for channel <- [:email, :sms, :push, :in_app] do
        links = %{approval: true, access_link: @access, response_link: @response}
        built = Request.build(input(Map.put(links, :channel, channel)))
        assert built.data["link"] == @access
        assert built.links == %{"primary" => @access}
        refute inspect(built) =~ "respond.example"
      end
    end

    test "AG-30: the inbox item of a request never carries the response link" do
      built = Request.build(input(%{channel: :in_app, response_link: @response}))
      assert built.cell["actions"] == []
      refute inspect(built) =~ "respond.example"
      sms = Request.build(input(%{channel: :sms, response_link: @response}))
      assert sms.data["link"] == @response
    end

    test "AG-35: the closing copy has no action, no field and no claim" do
      links = %{access_link: @access, response_link: @response}
      changes = Map.merge(links, %{copy: :closed, state: "resolved"})

      for channel <- [:push, :in_app] do
        built = Request.build(input(Map.put(changes, :channel, channel)))
        assert built.data["heading"] == "Request closed"
        assert built.links == %{}
        refute Map.has_key?(built.data, "claim")
        refute Map.has_key?(built.data, "label_0")
        assert %{"key" => "state", "value" => "resolved"} in built.rows
        assert %{"key" => "awaiting_response", "value" => "false"} in built.rows
      end
    end
  end

  describe "AG-63 the surfaces of an invitation" do
    @phone <<1::128>>
    @tablet <<2::128>>

    defp devices do
      [
        %{"id" => @phone, "platform" => "fcm", "permission" => "granted"},
        %{"id" => @tablet, "platform" => "web_push", "permission" => "granted"},
        %{"id" => <<3::128>>, "platform" => "apns", "permission" => "denied"}
      ]
    end

    defp channels(targets), do: Enum.map(targets, &{&1.channel, &1.device_id})

    test "AG-28: without named surfaces every address, permitted device and the inbox are taken" do
      recipient = %{"email_state" => "active", "phone_state" => "active"}

      assert channels(Surfaces.select(nil, true, recipient, devices())) == [
               {:email, nil},
               {:sms, nil},
               {:push, @phone},
               {:web_push, @tablet},
               {:in_app, nil}
             ]
    end

    test "AG-63: named surfaces narrow, exceptions take the rest, a missing surface is left out" do
      recipient = %{"email_state" => "active", "phone_state" => "disabled"}
      named = [%{"channel" => "sms"}, %{"channel" => "push"}]

      assert channels(Surfaces.select(named, false, recipient, devices())) == [{:push, @phone}]

      assert channels(Surfaces.select(%{"except" => named}, false, recipient, devices())) == [
               {:email, nil},
               {:web_push, @tablet}
             ]

      assert Surfaces.select([%{"channel" => "sms"}], false, recipient, []) == []
    end
  end
end
