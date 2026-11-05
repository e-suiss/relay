defmodule Relay.Channels.Email.DsnCorpusTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Email.Bounce
  alias Relay.Channels.Email.Bundled
  alias Relay.Channels.Email.Dsn
  alias Relay.Channels.Email.Mime

  @dir Path.expand("../../../fixtures/email/dsn", __DIR__)
  @manifest @dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

  defp table, do: Bundled.content("email_bounce_codes")
  defp read_vector(file), do: File.read!(Path.join(@dir, file))

  describe "CH-77 DSN corpus" do
    test "CH-77: every vector in the directory is listed with its source" do
      files = @dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".eml")) |> Enum.sort()
      listed = @manifest["vectors"] |> Enum.map(& &1["file"]) |> Enum.sort()

      assert files == listed
      assert Enum.all?(@manifest["vectors"], &(is_binary(&1["source"]) and &1["source"] != ""))
    end

    for vector <- @manifest["vectors"] do
      @vector vector

      test "CH-39: #{vector["file"]} classifies as listed (#{vector["source"]})" do
        case Bounce.classify_message(read_vector(@vector["file"]), table()) do
          {:dsn, report, results} ->
            assert @vector["report"] == "dsn"
            assert length(results) == length(@vector["recipients"])

            report.recipients
            |> Enum.zip(results)
            |> Enum.zip(@vector["recipients"])
            |> Enum.each(fn {{recipient, result}, expected} ->
              assert recipient.action == expected["action"]
              assert result.status == expected["status"]
              assert Atom.to_string(result.kind) == expected["kind"]
              assert result.rule == expected["rule"]
            end)

          {:unknown, [result]} ->
            assert @vector["report"] == "unknown"
            assert result.kind == :unknown
            assert Bounce.unknown_code?(result)
        end
      end
    end
  end

  describe "CH-39 RFC 3464 fields" do
    test "CH-39: per-message and per-recipient fields are read and addresses are redacted" do
      assert {:ok, report} = Dsn.parse(read_vector("rfc3464_simple.eml"))
      assert report.report_type == "delivery-status"
      assert report.reporting_mta == "dns; cs.utk.edu"

      assert [recipient] = report.recipients
      assert Relay.Redacted.expose(recipient.final_recipient) == "louisl@larry.slip.umd.edu"
      assert Relay.Redacted.expose(recipient.original_recipient) == "louisl@larry.slip.umd.edu"
      assert recipient.status == {4, 0, 0}
      assert recipient.diagnostic_type == "smtp"
      assert Relay.Redacted.expose(recipient.diagnostic) == "426 connection timed out"
      refute inspect(recipient) =~ "louisl"
    end

    test "CH-39: a folded diagnostic is unfolded" do
      message = read_vector("rfc3464_multi_recipient.eml")
      assert {:ok, %{recipients: [first | _]}} = Dsn.parse(message)

      assert Relay.Redacted.expose(first.diagnostic) ==
               "550 'arathib@vnet.IBM.COM' is not a registered gateway user"
    end

    test "CH-38: the original header fields carry the Feedback-ID and Message-ID" do
      assert {:ok, report} = Dsn.parse(read_vector("postfix_user_unknown.eml"))
      assert Mime.header(report.original_headers, "feedback-id") == "weekly:digest:tenant1:news"
      assert Mime.header(report.original_headers, "message-id") == "<msg-0001@sender.example>"

      assert {:ok, report} = Dsn.parse(read_vector("exim_no_such_user.eml"))
      assert Mime.header(report.original_headers, "feedback-id") ==
               "invoice:billing:tenant1:billing"
    end

    test "CH-39: an internationalized delivery status names its UTF-8 address" do
      assert {:ok, %{recipients: [recipient]}} = Dsn.parse(read_vector("global_dsn.eml"))
      assert Relay.Redacted.expose(recipient.final_recipient) == "yönetici@örnek.example"
    end

    test "CH-39: the original envelope identifier is read" do
      assert {:ok, report} = Dsn.parse(read_vector("rfc6522_partial_delivery.eml"))
      assert report.original_envelope_id == "env-0042"
    end

    test "CH-77: a message without a delivery status part is not a report" do
      assert Dsn.parse(read_vector("plain_text_bounce.eml")) == {:error, :not_a_report}
    end
  end
end
