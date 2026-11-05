defmodule Relay.Channels.WhatsappTemplatesTest do
  use Relay.DataCase, async: false

  alias Relay.Datasets
  alias RelayTest.TenantFixture

  @datasets ["channel_event_evidence", "whatsapp_messaging_limits"]
  @components [%{"type" => "BODY", "text" => "Merhaba {{1}}, siparişiniz yolda."}]

  defp forget do
    for name <- @datasets,
        do: :ok = Datasets.Cache.invalidate(Datasets.Cache, {Datasets.installation_scope(), name})
  end

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    on_exit(&forget/0)
    :ok
  end

  defp scope, do: TenantFixture.tenant!().live

  defp account(scope) do
    attrs = %{
      id: Relay.Id.generate(),
      channel: "whatsapp",
      provider: "whatsapp_cloud",
      ownership: "shared",
      role: "primary",
      priority: 0,
      in_installation: false,
      processing_countries: ["US"],
      transfer_basis: "explicit_consent",
      settings: %{"phone_number_id" => "1065", "waba_id" => "1022"}
    }

    digest = TenantFixture.digest()
    {:ok, {:created, 1}} = Relay.Channels.put_account(scope, attrs, digest, TenantFixture.actor())
    %{"id" => attrs.id, "settings" => attrs.settings}
  end

  defp register(scope, account, fields \\ %{}) do
    attrs =
      Map.merge(
        %{
          provider_account_id: account["id"],
          waba_id: "1022",
          name: "order_shipped_v3",
          language: "tr",
          message_class: "transactional",
          components: @components
        },
        fields
      )

    {:ok, row} = Relay.Channels.whatsapp_template_row(attrs)

    {:ok, result} =
      Relay.Repo.in_scope(scope, fn _status -> Relay.Channels.insert_whatsapp_template(row) end)

    result
  end

  defp webhook(scope, account, field, value) do
    body =
      Jason.encode!(%{
        "object" => "whatsapp_business_account",
        "entry" => [%{"id" => "1022", "changes" => [%{"field" => field, "value" => value}]}]
      })

    mac = Base.encode16(:crypto.mac(:hmac, :sha256, "app-secret", body), case: :lower)
    headers = [{"x-hub-signature-256", "sha256=" <> mac}]
    secret = Relay.Redacted.wrap("app-secret")
    Relay.Channels.Live.whatsapp_inbound(scope, account, secret, body, headers)
  end

  defp status(name, event, reason \\ nil) do
    %{
      "event" => event,
      "message_template_id" => 4242,
      "message_template_name" => name,
      "message_template_language" => "tr",
      "reason" => reason
    }
  end

  defp events(scope, type) do
    sql = "SELECT payload FROM relay.outbox_events WHERE event_type = $1 ORDER BY created_at, id"

    {:ok, rows} =
      Relay.Repo.in_scope(scope, fn _status -> Relay.Repo.scoped_query!(sql, [type]).rows end)

    Enum.map(rows, &hd/1)
  end

  defp sendable(scope, account, name),
    do: Relay.Channels.whatsapp_template_sendable(scope, account["id"], content(name))

  defp meta(scope, account, value),
    do: webhook(scope, account, "message_template_status_update", value)

  defp content(name), do: %{"template_name" => name, "language" => "tr"}

  describe "CH-57 TP-23 WhatsApp templates" do
    test "CH-57: a registration starts pending, is immutable and takes its class's category" do
      scope = scope()
      account = account(scope)

      assert {:created, id} = register(scope, account)
      assert {:exists, ^id} = register(scope, account)

      changed = [%{"type" => "BODY", "text" => "Yeni metin {{1}}"}]
      assert {:content_conflict, ^id} = register(scope, account, %{components: changed})

      assert {:account_not_found, nil} =
               register(scope, account, %{provider_account_id: Relay.Id.generate()})

      assert {:ok, row} = Relay.Channels.get_whatsapp_template(scope, id)
      assert %{"status" => "pending_approval", "category" => "utility"} = row

      assert sendable(scope, account, row["name"]) == {:error, "pending_approval"}
      assert sendable(scope, account, "other_v1") == {:error, :not_registered}
    end

    test "CH-60, TP-23: Meta's statuses move the state once, a pause stops sending and a rejection keeps Meta's reason" do
      scope = scope()
      account = account(scope)
      {:created, id} = register(scope, account)

      approved = status("order_shipped_v3", "APPROVED")
      assert {:ok, 1} = meta(scope, account, approved)
      assert {:ok, 0} = meta(scope, account, approved)
      assert sendable(scope, account, "order_shipped_v3") == :ok

      assert {:ok, row} = Relay.Channels.get_whatsapp_template(scope, id)
      assert row["approved_components"] == @components
      assert row["meta_template_id"] == "4242"

      assert {:ok, 1} = meta(scope, account, status("order_shipped_v3", "PAUSED"))
      assert sendable(scope, account, "order_shipped_v3") == {:error, "paused"}

      {:created, other} = register(scope, account, %{name: "order_shipped_v4"})
      rejected = status("order_shipped_v4", "REJECTED", "INCORRECT_CATEGORY")
      assert {:ok, 1} = meta(scope, account, rejected)
      assert {:ok, row} = Relay.Channels.get_whatsapp_template(scope, other)
      assert %{"status" => "rejected", "rejection_reason" => "INCORRECT_CATEGORY"} = row

      statuses = Enum.map(events(scope, "whatsapp_template.status_changed"), & &1["status"])
      assert statuses == ["approved", "paused", "rejected"]
    end

    test "CH-57: a category change is a drift announced to the tenant and the Relay class stays" do
      scope = scope()
      account = account(scope)
      {:created, id} = register(scope, account)

      change = %{
        "message_template_name" => "order_shipped_v3",
        "message_template_language" => "tr",
        "previous_category" => "UTILITY",
        "new_category" => "MARKETING"
      }

      assert {:ok, 1} = webhook(scope, account, "template_category_update", change)
      assert {:ok, row} = Relay.Channels.get_whatsapp_template(scope, id)
      assert %{"message_class" => "transactional", "category" => "utility"} = row
      assert row["meta_category"] == "marketing"

      assert [%{"new_category" => "marketing", "category" => "utility"}] =
               events(scope, "whatsapp_template.category_changed")

      drift = Relay.Api.WhatsappTemplates.view(row)["category_drift"]
      assert drift == %{"expected" => "utility", "actual" => "marketing", "cost_increase" => true}
    end

    test "CH-60: a webhook with a bad signature applies nothing" do
      scope = scope()
      account = account(scope)
      secret = Relay.Redacted.wrap("other-secret")
      body = ~s({"object":"whatsapp_business_account","entry":[]})
      headers = [{"x-hub-signature-256", "sha256=00"}]

      assert {:error, :bad_signature} =
               Relay.Channels.Live.whatsapp_inbound(scope, account, secret, body, headers)
    end
  end
end
