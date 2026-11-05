defmodule Relay.Channels.Email.ArfCorpusTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Email.Arf
  alias Relay.Channels.Email.Bounce
  alias Relay.Channels.Email.Bundled
  alias Relay.Channels.Email.Mime

  @dir Path.expand("../../../fixtures/email/arf", __DIR__)
  @manifest @dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

  defp read_vector(file), do: File.read!(Path.join(@dir, file))

  describe "CH-77 ARF corpus" do
    test "CH-77: every vector in the directory is listed with its source" do
      files = @dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".eml")) |> Enum.sort()
      listed = @manifest["vectors"] |> Enum.map(& &1["file"]) |> Enum.sort()

      assert files == listed
      assert Enum.all?(@manifest["vectors"], &(is_binary(&1["source"]) and &1["source"] != ""))
    end

    for vector <- @manifest["vectors"] do
      @vector vector

      test "CH-39: #{vector["file"]} classifies as listed (#{vector["source"]})" do
        message = read_vector(@vector["file"])
        table = Bundled.content("email_bounce_codes")

        case Bounce.classify_message(message, table) do
          {:arf, report, result} ->
            assert report.feedback_type == @vector["feedback_type"]
            assert report.conformant == @vector["conformant"]
            assert Atom.to_string(result.kind) == @vector["kind"]
            assert Mime.header(report.original_headers, "message-id") == @vector["message_id"]
            assert Mime.header(report.original_headers, "feedback-id") == @vector["feedback_id"]

          {:unknown, [result]} ->
            assert @vector["kind"] == "unknown"
            assert result.rule == "arf:invalid"
            assert Bounce.unknown_code?(result)
        end
      end
    end
  end

  describe "CH-39 RFC 5965 fields" do
    test "CH-39: the optional fields of the full report are read, addresses redacted" do
      assert {:ok, report} = Arf.parse(read_vector("rfc5965_full.eml"))
      assert Relay.Redacted.expose(report.original_mail_from) == "somespammer@example.net"
      assert Enum.map(report.original_rcpt_to, &Relay.Redacted.expose/1) == ["user@example.com"]
      assert report.reporting_mta == "dns; mail.example.com"
      assert report.source_ip == "192.0.2.1"
      assert report.reported_domains == ["example.net"]
      assert report.incidents == 1
      refute inspect(report.original_rcpt_to) =~ "user@example.com"
    end

    test "CH-38: the VERP return path of the reported message is in its original header fields" do
      assert {:ok, report} = Arf.parse(read_vector("microsoft_jmrp.eml"))

      assert Mime.header(report.original_headers, "return-path") ==
               "<b-example@bounce.sender.example>"

      assert Relay.Redacted.expose(report.original_mail_from) == "b-example@bounce.sender.example"
    end

    test "CH-39: a complaint suppresses; an auth failure never does" do
      table = Bundled.content("email_bounce_codes")

      assert {:arf, _report, complaint} =
               Bounce.classify_message(read_vector("yahoo_cfl.eml"), table)

      assert %{failure_class: "policy", suppression: "complaint", reputation: :complaint} =
               complaint

      assert {:arf, _report, auth} =
               Bounce.classify_message(read_vector("rfc6591_auth_failure.eml"), table)

      assert %{kind: :sender_config, failure_class: "sender_config", suppression: nil} = auth
      assert Bounce.subscriber_untouched?(auth)
    end

    test "CH-77: a delivery status notification is not a feedback report" do
      dsn = Path.expand("../../../fixtures/email/dsn/gmail_dmarc.eml", __DIR__)
      assert Arf.parse(File.read!(dsn)) == {:error, :not_a_report}
    end
  end
end
