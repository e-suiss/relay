defmodule Relay.Webhooks.EnvelopeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Webhooks.Envelope

  @time ~U[2026-11-07 09:30:00Z]
  @traceparent "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
  @schema "https://relay.example/schemas/notification.delivered/1"

  defp fields(extra) do
    Map.merge(
      %{
        id: "evt_1",
        source: "https://relay.example/issuer",
        type: "notification.delivered",
        time: @time,
        subject: "notification/ntf_1",
        dataschema: @schema,
        data: %{"notification_id" => "ntf_1", "delivery_id" => "dlv_1"},
        seq: 7,
        traceparent: @traceparent,
        environment: :live
      },
      extra
    )
  end

  defp envelope(usage \\ :relay_events, extra \\ %{}) do
    {:ok, envelope} = Envelope.new(usage, fields(extra))
    envelope
  end

  defp flat(max), do: map_of(string(:alphanumeric, min_length: 1), integer(), max_length: max)

  defp subset(source), do: list_of(member_of(["absent" | Map.keys(source)]), max_length: 10)

  defp decoded(body), do: Jason.decode!(body, objects: :ordered_objects)

  defp keys(%Jason.OrderedObject{values: values}), do: Enum.map(values, &elem(&1, 0))

  describe "WH-8 structured mode" do
    test "WH-8: the body is CloudEvents 1.0 structured JSON with its attributes in a fixed order" do
      body = Envelope.encode(envelope())

      order = [
        "specversion",
        "id",
        "source",
        "type",
        "time",
        "subject",
        "datacontenttype",
        "dataschema",
        "environment",
        "seq",
        "traceparent",
        "data"
      ]

      content = %{
        "specversion" => "1.0",
        "id" => "evt_1",
        "source" => "https://relay.example/issuer",
        "type" => "notification.delivered",
        "time" => "2026-11-07T09:30:00Z",
        "subject" => "notification/ntf_1",
        "datacontenttype" => "application/json",
        "dataschema" => @schema,
        "environment" => "live",
        "seq" => 7,
        "traceparent" => @traceparent,
        "data" => %{"notification_id" => "ntf_1", "delivery_id" => "dlv_1"}
      }

      assert keys(decoded(body)) == order
      assert Jason.decode!(body) == content
      assert Envelope.content_type() == "application/cloudevents+json; charset=utf-8"
    end

    test "WH-8: attributes that are absent are left out, and extensions are sorted by name" do
      fields = %{
        id: "evt_2",
        source: "https://relay.example/issuer",
        type: "webhook_endpoint.disabled",
        time: @time,
        extensions: %{"correlationid" => "c-1", "accesstenant" => "t-1"}
      }

      {:ok, envelope} = Envelope.new(:relay_events, fields)

      assert keys(decoded(Envelope.encode(envelope))) ==
               ~w(specversion id source type time datacontenttype accesstenant correlationid data)

      assert Jason.decode!(Envelope.encode(envelope))["data"] == %{}
    end

    test "WH-8: the same event gives the same bytes and the same digest on every attempt" do
      first = Envelope.encode(envelope())
      second = Envelope.encode(envelope())

      assert first == second
      assert :crypto.hash(:sha256, first) == :crypto.hash(:sha256, second)
    end

    property "WH-8: the keys of every object in data are written in sorted order" do
      check all inner <- flat(60) do
        data = Map.put(inner, "nested", %{"items" => [inner, %{"z" => 1, "a" => 2}]})
        written = decoded(Envelope.encode(envelope(:relay_events, %{data: data})))["data"]

        assert keys(written) == Enum.sort(Map.keys(data))
        [first, second] = written["nested"]["items"]
        assert keys(first) == Enum.sort(Map.keys(inner))
        assert keys(second) == ["a", "z"]
      end
    end
  end

  describe "WH-8 binary mode" do
    test "WH-8: the context attributes travel as the headers of the protocol binding" do
      envelope = envelope(:relay_events, %{subject: "sipariş 1"})
      attributes = Envelope.attributes(envelope)

      assert {"specversion", "1.0"} in attributes
      assert {"seq", "7"} in attributes
      assert {"time", "2026-11-07T09:30:00Z"} in attributes
      refute List.keymember?(attributes, "data", 0)

      kafka = Envelope.binary_headers(attributes, :kafka)
      assert {"ce_id", "evt_1"} in kafka
      assert {"ce_subject", "sipariş 1"} in kafka
      refute List.keymember?(kafka, "ce_datacontenttype", 0)

      amqp = Envelope.binary_headers(attributes, :amqp)
      assert {"cloudEvents:type", "notification.delivered"} in amqp

      for binding <- [:http, :nats] do
        headers = Envelope.binary_headers(attributes, binding)
        assert {"ce-id", "evt_1"} in headers
        assert {"ce-subject", "sipari%C5%9F%201"} in headers
        assert {"ce-environment", "live"} in headers
      end

      assert Envelope.data_body(envelope) == ~s({"delivery_id":"dlv_1","notification_id":"ntf_1"})
    end
  end

  describe "WH-8 no internal identifier for a tenant's customers" do
    test "WH-8: a destination envelope refuses the extensions that only Relay's own events carry" do
      for name <- ~w(accesstenant accessorganization correlationid) do
        extensions = %{name => "value"}

        assert {:error, :extension_not_allowed} =
                 Envelope.new(:destination, fields(%{extensions: extensions}))

        assert {:ok, own} = Envelope.new(:relay_events, fields(%{extensions: extensions}))
        assert Jason.decode!(Envelope.encode(own))[name] == "value"
      end
    end

    test "WH-8: a destination envelope carries the tenant's source and nothing that was not given" do
      body =
        :destination
        |> envelope(%{source: "https://shop.example/orders", extensions: %{"region" => "tr"}})
        |> Envelope.encode()

      assert Jason.decode!(body)["source"] == "https://shop.example/orders"

      assert keys(decoded(body)) -- ~w(specversion datacontenttype) ==
               ~w(id source type time subject dataschema environment region seq traceparent data)
    end

    test "WH-8: fields that are not valid attributes are refused" do
      shifted = %{@time | utc_offset: 10_800, time_zone: "Europe/Istanbul", zone_abbr: "+03"}

      refused = [
        {%{id: "evt 1"}, :invalid_id},
        {%{id: nil}, :invalid_id},
        {%{source: ""}, :invalid_source},
        {%{type: nil}, :invalid_type},
        {%{time: shifted}, :invalid_time},
        {%{time: ~N[2026-11-07 09:30:00]}, :invalid_time},
        {%{subject: ""}, :invalid_attribute},
        {%{seq: -1}, :invalid_attribute},
        {%{environment: :staging}, :invalid_attribute},
        {%{data: [1]}, :invalid_data},
        {%{extensions: %{"Bad-Name" => "x"}}, :invalid_extension},
        {%{extensions: %{"seq" => 1}}, :invalid_extension},
        {%{extensions: %{"data" => "x"}}, :invalid_extension},
        {%{extensions: %{"region" => %{"a" => 1}}}, :invalid_extension}
      ]

      for {extra, error} <- refused do
        assert Envelope.new(:relay_events, fields(extra)) == {:error, error}
      end
    end
  end

  describe "WH-11 WH-12 WH-13 payload" do
    test "WH-11: the thin payload holds the declared identifiers and nothing else" do
      data = %{"notification_id" => "ntf_1", "delivery_id" => "dlv_1", "email" => "a@b.example"}

      assert Envelope.thin(data, ["notification_id", "delivery_id", "rule_id"]) ==
               %{"notification_id" => "ntf_1", "delivery_id" => "dlv_1"}
    end

    test "WH-12: a snapshot adds exactly the allow-listed fields" do
      thin = %{"order_id" => "o-1"}

      source = %{
        "order_id" => "changed",
        "status" => "shipped",
        "customer" => %{"locale" => "tr", "email" => "a@b.example"},
        "total" => 120
      }

      assert Envelope.snapshot(thin, source, ["status", "customer.locale", "missing.path"]) ==
               %{"order_id" => "o-1", "status" => "shipped", "customer" => %{"locale" => "tr"}}

      assert Envelope.snapshot(thin, source, []) == thin
      assert Envelope.snapshot(thin, source, ["order_id"]) == thin
    end

    property "WH-12: no field outside the allow-list reaches the payload" do
      check all source <- flat(20), allowed <- subset(source) do
        assert Envelope.snapshot(%{}, source, allowed) == Map.take(source, allowed)
      end
    end

    test "WH-13: CloudEvents attributes are filled from the fields of the tenant event" do
      envelope = envelope(:destination, %{subject: nil, source: "https://shop.example/orders"})
      data = %{"order" => %{"id" => "o-1", "lines" => [1, 2]}, "store" => %{"region" => "tr"}}
      mapping = %{"subject" => "order.id", "region" => "store.region", "lines" => "order.lines"}

      assert {:ok, mapped} = Envelope.map_attributes(envelope, data, mapping)
      assert mapped.subject == "o-1"
      assert mapped.extensions == %{"region" => "tr"}

      assert {:ok, ^envelope} = Envelope.map_attributes(envelope, data, %{"subject" => "nope"})

      for attribute <- ~w(id source type time data seq accesstenant correlationid Bad-Name) do
        assert {:error, :attribute_not_mappable} =
                 Envelope.map_attributes(envelope, data, %{attribute => "order.id"})
      end
    end

    test "WH-20: the ordering key of a partitioned destination is the subject of the event" do
      assert Envelope.partition_key(envelope()) == "notification/ntf_1"
      assert Envelope.partition_key(envelope(:relay_events, %{subject: nil})) == nil
    end
  end

  describe "WH-29 payload size" do
    test "WH-29: the payload is measured in bytes against the hard limit" do
      limit = 262_144

      assert Envelope.size("şş") == 4
      assert Envelope.check_size(String.duplicate("a", limit), limit) == :ok

      assert Envelope.check_size(String.duplicate("a", limit + 1), limit) ==
               {:error, {:payload_too_large, limit + 1}}

      assert Envelope.size(Envelope.encode(envelope())) < 20_000
    end
  end
end
