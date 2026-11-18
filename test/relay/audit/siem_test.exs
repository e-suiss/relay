defmodule Relay.Audit.SiemTest do
  use ExUnit.Case, async: true

  alias Relay.Audit.Checkpointer.Publisher.Customer
  alias Relay.Audit.Checkpointer.Publisher.Https
  alias Relay.Audit.Checkpointer.Publisher.Siem
  alias Relay.Audit.Checkpointer.Stream

  @opts [
    url: "https://siem.example/intake",
    hmac_label: "siem-intake",
    req_options: [plug: {Req.Test, __MODULE__}]
  ]

  @checkpoint %{
    id: <<1::128>>,
    origin: "relay.test/relay/audit/2026",
    tree_size: 7,
    root_hash: :binary.copy(<<7>>, 32),
    signed_note: "relay.test/relay/audit/2026\n7\nBwcH\n\n— relay sig\n",
    key_ref: "pkcs11:object=audit-checkpoint",
    heartbeat: false
  }

  defp record(index) do
    %{
      leaf_index: index,
      tenant_id: <<1::128>>,
      environment: "live",
      id: <<index::128>>,
      created_at: ~U[2026-11-18 10:00:00.000000Z],
      action: "tenant.closed",
      actor_kind: "installation_operator",
      actor_ref: "platform-op",
      on_behalf_of_ref: "platform-op",
      access_record_ref: "stepup-1",
      target_type: "tenant",
      target_id: "t",
      reason: "contract ended",
      record_digest: :binary.copy(<<index>>, 32)
    }
  end

  defp capture(status \\ 200) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [signature] = Plug.Conn.get_req_header(conn, "relay-signature")
      [type] = Plug.Conn.get_req_header(conn, "content-type")
      send(test_pid, {:posted, conn.request_path, type, signature, body})
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  defp verify!(signature, body) do
    ["t=" <> t, "v1=" <> mac] = String.split(signature, ",")
    expected = :crypto.mac(:hmac, :sha256, RelayTest.Keys.secret("siem-intake"), t <> "." <> body)
    assert mac == Base.encode16(expected, case: :lower)
  end

  describe "TN-46 TN-49 SIEM target" do
    test "TN-46: a checkpoint goes to the SIEM as one signed JSON line" do
      capture()
      assert :ok = Siem.publish(@checkpoint, @opts)
      assert_received {:posted, "/intake", "application/x-ndjson", signature, body}
      verify!(signature, body)

      assert %{"type" => "audit_checkpoint", "tree_size" => 7, "signed_note" => note} =
               Jason.decode!(body)

      assert note == @checkpoint.signed_note
      assert String.ends_with?(body, "\n")
    end

    test "TN-49: audit records are streamed as a signed batch of JSON lines in log order" do
      capture()
      assert :ok = Siem.stream(@checkpoint.origin, [record(3), record(4)], @opts)
      assert_received {:posted, "/intake", _type, signature, body}
      verify!(signature, body)

      assert [%{"leaf_index" => 3, "action" => "tenant.closed"}, %{"leaf_index" => 4}] =
               body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    end

    test "TN-49: a refused batch is an error, so the stream sends it again" do
      capture(503)

      assert {:error, %Relay.Error{code: :publication_refused}} =
               Siem.stream(@checkpoint.origin, [record(1)], @opts)
    end

    test "TN-49: the stream moves its cursor only when every streaming target took the batch" do
      targets = [{"siem", Siem, @opts}]
      assert Stream.targets([{"worm_store", Relay.Audit.Checkpointer.Publisher.S3, []}]) == []
      assert Stream.targets(targets) == targets

      assert {:ok, %{"origin" => "o", "next" => 0}, _delay} = Stream.step(nil, "o", [])

      assert {:ok, %{"origin" => "o", "next" => 12}, _delay} =
               Stream.step(%{"origin" => "o", "next" => 12}, "o", [])
    end

    test "TN-46: SIEM and customer options are validated" do
      assert :ok = Siem.validate(Keyword.delete(@opts, :req_options))
      assert {:error, _} = Siem.validate(url: "ftp://siem", hmac_label: "k")
      assert {:error, _} = Siem.validate(url: "https://siem")
      assert {:error, _} = Siem.validate(url: "https://siem", hmac_label: "k", extra: 1)

      assert :ok = Customer.validate([kind: :webhook] ++ Keyword.delete(@opts, :req_options))
      assert {:error, _} = Customer.validate(url: "https://c", hmac_label: "k")
      assert Siem.independent?() and Customer.independent?()
    end

    test "TN-46: a customer webhook target gets the signed checkpoint" do
      capture()
      assert :ok = Customer.publish(@checkpoint, [kind: :webhook] ++ @opts)
      assert_received {:posted, "/intake", _type, signature, body}
      verify!(signature, body)
    end

    test "TN-46: the signature covers the time and the body" do
      assert {:ok, "t=100,v1=" <> a} = Https.signature("siem-intake", 100, "x")
      assert {:ok, "t=101,v1=" <> b} = Https.signature("siem-intake", 101, "x")
      assert a != b
    end
  end
end
