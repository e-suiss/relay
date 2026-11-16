defmodule Relay.Channels.ReceiptQueueTest do
  use Relay.DataCase, async: false

  alias Relay.Channels.Email.Sns
  alias Relay.Channels.Live
  alias Relay.Channels.Live.ReceiptWorker
  alias Relay.Channels.Live.SesQueue
  alias Relay.Channels.Whatsapp.Message
  alias Relay.Datasets
  alias RelayTest.DeliveryFixture
  alias RelayTest.IngestFixture
  alias RelayTest.TenantFixture

  @datasets ["channel_event_evidence", "email_bounce_codes"]
  @receipts "Relay.Channels.Live.ReceiptWorker"
  @topic "arn:aws:sns:eu-central-1:123456789012:relay"
  @cert_url "https://sns.eu-central-1.amazonaws.com/SimpleNotificationService-abc.pem"
  @queue "https://sqs.eu-central-1.amazonaws.com/123456789012/relay-events"

  defp forget do
    for name <- @datasets,
        do: Datasets.Cache.invalidate(Datasets.Cache, {Datasets.installation_scope(), name})
  end

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    on_exit(&forget/0)
    :ok
  end

  defp run_receipts(scope) do
    for [text] <- IngestFixture.jobs(@receipts, scope, "receipt_ids") do
      args = Map.put(Relay.Scope.to_job_args(scope), "receipt_ids", Jason.decode!(text))
      :ok = ReceiptWorker.perform(%Oban.Job{args: args})
    end
  end

  defp reported(scope, delivery_id) do
    {:ok, ledger} = Relay.Delivery.ledger(scope, delivery_id)
    Enum.filter(ledger, &(&1["event_type"] == "provider.reported"))
  end

  defp credential!(scope, value) do
    var = "RELAY_TEST_SES_" <> String.upcase(TenantFixture.random())
    System.put_env(var, Jason.encode!(value))
    on_exit(fn -> System.delete_env(var) end)
    id = Relay.Id.generate()

    attrs = %{
      id: id,
      kind: :provider_credential,
      ref: "${#{var}}",
      ref_version: 1,
      record_digest: TenantFixture.digest()
    }

    {:ok, :created} = Relay.Secrets.register(scope, attrs, TenantFixture.actor())
    id
  end

  defp ses_account(scope) do
    credential = credential!(scope, %{"access_key_id" => "AK", "secret_access_key" => "SK"})
    ses = %{"region" => "eu-central-1", "queue_url" => @queue, "topic_arn" => @topic}
    settings = %{"ses" => ses}

    %{
      "id" => Relay.Id.generate(),
      "provider" => "ses",
      "settings" => settings,
      "credential_ref_id" => credential
    }
  end

  defp notification(message, key) do
    fields = %{
      "Type" => "Notification",
      "MessageId" => "sns-1",
      "TopicArn" => @topic,
      "Message" => Jason.encode!(message),
      "Timestamp" => "2026-11-05T10:00:00.000Z",
      "SignatureVersion" => "2",
      "SigningCertURL" => @cert_url
    }

    signature = :public_key.sign(Sns.canonical(fields), :sha256, key)
    Map.put(fields, "Signature", Base.encode64(signature))
  end

  defp bounce(delivery_id) do
    %{
      "eventType" => "Bounce",
      "mail" => %{
        "messageId" => "ses-1",
        "tags" => %{"relay_delivery_id" => [Relay.Id.to_string(delivery_id)]}
      },
      "bounce" => %{
        "bounceType" => "Permanent",
        "bounceSubType" => "General",
        "timestamp" => "2026-11-05T10:00:00.000Z",
        "bouncedRecipients" => [
          %{
            "emailAddress" => "reader@example.com",
            "action" => "failed",
            "status" => "5.1.1",
            "diagnosticCode" => "smtp; 550 5.1.1 user unknown"
          }
        ]
      }
    }
  end

  defp root_cert(name), do: :public_key.pkix_test_root_cert(name, key: {:rsa, 2048, 65_537})

  defp sqs(conn, body) do
    target = conn |> Plug.Conn.get_req_header("x-amz-target") |> List.first()
    answer = sqs_answer(target, body)

    conn
    |> Plug.Conn.put_resp_content_type("application/x-amz-json-1.0")
    |> Plug.Conn.send_resp(200, Jason.encode!(answer))
  end

  defp sqs_answer("AmazonSQS.DeleteMessage", _body) do
    Process.put(:deleted, (Process.get(:deleted) || 0) + 1)
    %{}
  end

  defp sqs_answer(_receive, body) do
    if Process.get(:deleted),
      do: %{},
      else: %{"Messages" => [%{"ReceiptHandle" => "rh-1", "Body" => body}]}
  end

  describe "CH-47 WH-49 SES event queue" do
    test "CH-47, WH-49, T-40: a verified SES event becomes a receipt before its message is deleted, and its batch writes it" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      %{cert: der, key: key} = root_cert(~c"SNS test")
      pem = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
      fetch = fn @cert_url -> {:ok, pem} end
      body = Jason.encode!(notification(bounce(id), key))

      Req.Test.stub(Relay.Channels.Email.Esp, &sqs(&1, body))

      assert {:ok, %{received: 1, recorded: 1, rejected: 0}} =
               SesQueue.drain(scope, ses_account(scope), fetch: fetch, wait_s: 0)

      assert Process.get(:deleted) == 1
      run_receipts(scope)
      assert [%{"actor" => "provider_webhook"}] = reported(scope, id)
      assert {:ok, %{"failure_kind" => "bounced"}} = Relay.Delivery.delivery(scope, id)
    end

    test "CH-47, T-40: a message whose envelope does not verify is deleted and records nothing" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      %{key: key} = root_cert(~c"SNS test")
      %{cert: other} = root_cert(~c"Other")
      pem = :public_key.pem_encode([{:Certificate, other, :not_encrypted}])
      fetch = fn _url -> {:ok, pem} end
      body = Jason.encode!(notification(bounce(id), key))

      Req.Test.stub(Relay.Channels.Email.Esp, &sqs(&1, body))

      assert {:ok, %{received: 1, recorded: 0, rejected: 1}} =
               SesQueue.drain(scope, ses_account(scope), fetch: fetch, wait_s: 0)

      assert IngestFixture.jobs(@receipts, scope, "receipt_ids") == []
    end
  end

  describe "CH-60 WH-49 T-41 WhatsApp statuses from the queue" do
    test "CH-60, WH-49, T-41: a status is a receipt with its job when Meta is answered and is written by its batch once" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!(delivery: [channel: :whatsapp])
      account = %{"id" => Relay.Id.generate(), "provider" => "whatsapp_cloud", "settings" => %{}}

      status = %{
        "id" => "wamid.A",
        "status" => "delivered",
        "timestamp" => Integer.to_string(DateTime.to_unix(Relay.Clock.utc_now())),
        "recipient_id" => "905551112233",
        "biz_opaque_callback_data" => Message.correlation(id, 1)
      }

      value = %{
        "metadata" => %{"display_phone_number" => "15550783881", "phone_number_id" => "1065"},
        "statuses" => [status]
      }

      change = %{"field" => "messages", "value" => value}

      body =
        Jason.encode!(%{
          "object" => "whatsapp_business_account",
          "entry" => [%{"id" => "1022", "changes" => [change]}]
        })

      mac = Base.encode16(:crypto.mac(:hmac, :sha256, "app-secret", body), case: :lower)
      headers = [{"x-hub-signature-256", "sha256=" <> mac}]
      secret = Relay.Redacted.wrap("app-secret")

      assert {:ok, 1} = Live.whatsapp_inbound(scope, account, secret, body, headers)
      assert {:ok, 0} = Live.whatsapp_inbound(scope, account, secret, body, headers)
      assert reported(scope, id) == []

      run_receipts(scope)
      assert [%{"actor" => "provider_webhook"}] = reported(scope, id)
      assert {:ok, %{"delivery_rank" => 2}} = Relay.Delivery.delivery(scope, id)
    end
  end
end
