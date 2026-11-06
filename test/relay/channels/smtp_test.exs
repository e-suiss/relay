defmodule Relay.Channels.SmtpTest do
  use ExUnit.Case, async: true

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Email
  alias Relay.Channels.Email.Dkim
  alias Relay.Channels.Email.Mime
  alias Relay.Channels.Request
  alias Relay.Channels.Smtp
  alias RelayTest.SmtpServer

  @link "https://access.example/verify?t=abc123"
  @streams %{
    "streams" => %{
      "transactional" => %{
        "from" => "security@sender.example",
        "domain" => "sender.example",
        "selector" => "tx2026",
        "return_path_domain" => "bounce.sender.example",
        "ip_pool" => "tx",
        "queue" => "tx"
      },
      "marketing" => %{
        "from" => "news@news.sender.example",
        "domain" => "news.sender.example",
        "selector" => "mk2026",
        "return_path_domain" => "bounce.news.sender.example",
        "ip_pool" => "mk",
        "queue" => "mk"
      }
    }
  }

  setup_all do
    certs = SmtpServer.certificates()
    %{certs: certs, pem: pem(certs.cacerts)}
  end

  setup do
    Logger.metadata(correlation_id: "smtp-test")
    :ok
  end

  defp pem(cacerts),
    do: :public_key.pem_encode(for(der <- cacerts, do: {:Certificate, der, :not_encrypted}))

  defp request(port, mode, pem, overrides \\ %{}) do
    smtp =
      Map.merge(
        %{"host" => "localhost", "port" => port, "tls" => mode, "ca_certificates" => pem},
        Map.get(overrides, :smtp, %{})
      )

    %Request{
      scope: Relay.Scope.new!(Relay.Id.generate(), :live),
      delivery_id: Relay.Id.generate(),
      attempt_no: 1,
      channel: "email",
      provider: "smtp",
      idempotency_key: "key-1",
      target: %{
        kind: :address,
        id: nil,
        value: Relay.Redacted.wrap(Map.get(overrides, :to, "reader@example.com"))
      },
      timeout_ms: Map.get(overrides, :timeout_ms, 10_000),
      content:
        Map.get(overrides, :content, %{
          "subject" => "Confirm your address",
          "text" => "Confirm: " <> @link,
          "html" => ~s(<p><a href="#{@link}">Confirm</a></p>)
        }),
      credentials: Map.get(overrides, :credentials),
      account: %{"id" => Relay.Id.generate(), "settings" => Map.put(@streams, "smtp", smtp)},
      message_class: Map.get(overrides, :class, "security")
    }
  end

  defp session do
    receive do
      {:smtp_session, session} -> session
    after
      10_000 -> flunk("no SMTP session")
    end
  end

  defp public_key(request, domain, selector) do
    key = RelayTest.Keys.rs256(Email.dkim_key_label(request.scope, domain, selector))
    {:RSAPublicKey, elem(key, 2), elem(key, 3)}
  end

  defp declarations do
    {:ok, content} = ChannelDeclarations.compose()
    ChannelDeclarations.new(content, nil)
  end

  defp free_port do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)
    port
  end

  describe "CH-34 T-39 verified TLS" do
    test "CH-34, T-39: implicit TLS sends a signed message with the VERP return path", ctx do
      {:ok, port} = SmtpServer.start(mode: :implicit, tls: ctx.certs.server)
      request = request(port, "implicit", ctx.pem)

      assert {:accepted, %{provider_message_id: "2.0.0 Ok: queued as Q1"}} = Smtp.deliver(request)

      session = session()
      assert session.tls
      assert session.mail_from =~ ~r/\A<b-[a-z2-7]{42}@bounce\.sender\.example>\z/
      assert session.rcpt_to == ["<reader@example.com>"]
      assert :ok = Dkim.verify(session.data, public_key(request, "sender.example", "tx2026"))
      assert session.data =~ "Feedback-ID: security:security:"
      refute session.data =~ "List-Unsubscribe"
    end

    test "CH-34, T-39: STARTTLS upgrades the connection before the message", ctx do
      {:ok, port} = SmtpServer.start(mode: :starttls, tls: ctx.certs.server)
      request = request(port, "starttls", ctx.pem)

      assert {:accepted, _info} = Smtp.deliver(request)
      session = session()
      assert session.tls
      assert :ok = Dkim.verify(session.data, public_key(request, "sender.example", "tx2026"))
    end

    test "CH-34, T-39: a server that does not offer STARTTLS gets no message", ctx do
      {:ok, port} = SmtpServer.start(mode: :plain)

      assert {:rejected, %{code: "tls_unavailable"}} =
               Smtp.deliver(request(port, "starttls", ctx.pem))

      session = session()
      refute session.tls
      assert session.mail_from == nil
    end

    test "CH-34, T-39: a certificate for another host fails in both modes", _ctx do
      other = SmtpServer.certificates("mx.other.example")

      for {server_mode, mode} <- [implicit: "implicit", starttls: "starttls"] do
        {:ok, port} = SmtpServer.start(mode: server_mode, tls: other.server)

        assert {:rejected, %{code: "tls_failed"}} =
                 Smtp.deliver(request(port, mode, pem(other.cacerts)))

        assert session() == :handshake_failed
      end
    end

    test "CH-34, T-39: a certificate from an untrusted authority fails", ctx do
      {:ok, port} = SmtpServer.start(mode: :implicit, tls: ctx.certs.server)
      untrusted = SmtpServer.certificates()

      assert {:rejected, %{code: "tls_failed"}} =
               Smtp.deliver(request(port, "implicit", pem(untrusted.cacerts)))
    end

    test "CH-34, T-39: settings without verified TLS or with an IP host are refused", ctx do
      for smtp <- [%{"tls" => "none"}, %{"tls" => nil}, %{"host" => "127.0.0.1"}] do
        request = request(1025, "implicit", ctx.pem, %{smtp: smtp})
        assert {:rejected, %{code: "configuration_invalid"}} = Smtp.deliver(request)
      end
    end

    test "CH-34: the credential authenticates after TLS", ctx do
      {:ok, port} = SmtpServer.start(mode: :starttls, tls: ctx.certs.server, auth: true)
      credentials = Relay.Redacted.wrap(%{"username" => "relay", "password" => "s3cret"})

      assert {:accepted, _info} =
               Smtp.deliver(request(port, "starttls", ctx.pem, %{credentials: credentials}))

      assert session().auth == "AUTH PLAIN " <> Base.encode64(<<0, "relay", 0, "s3cret">>)
    end
  end

  describe "CH-7 CH-9 CH-10 replies and uncertainty" do
    test "CH-7, CH-39: a 5.1.1 refusal is a permanent target failure", ctx do
      {:ok, port} =
        SmtpServer.start(mode: :implicit, tls: ctx.certs.server, rcpt: "550 5.1.1 no such user")

      result = Smtp.deliver(request(port, "implicit", ctx.pem))
      assert {:rejected, %{code: "5.1.1", status: 550}} = result

      assert {:ok, outcome} = Relay.Channels.normalize(declarations(), "smtp", "email", result)
      assert outcome.failure_class == "permanent_target"
      assert outcome.event_code == "bounced"
    end

    test "CH-7, CH-39: a DMARC refusal is a sender configuration failure", ctx do
      {:ok, port} =
        SmtpServer.start(mode: :implicit, tls: ctx.certs.server, data: "550 5.7.26 DMARC fail")

      result = Smtp.deliver(request(port, "implicit", ctx.pem))
      assert {:ok, outcome} = Relay.Channels.normalize(declarations(), "smtp", "email", result)
      assert outcome.failure_class == "sender_config"
    end

    test "CH-7: a 4xx reply is transient", ctx do
      {:ok, port} =
        SmtpServer.start(mode: :implicit, tls: ctx.certs.server, data: "421 4.7.0 try later")

      result = Smtp.deliver(request(port, "implicit", ctx.pem))
      assert {:rejected, %{code: "4.7.0", status: 421}} = result
      assert {:ok, outcome} = Relay.Channels.normalize(declarations(), "smtp", "email", result)
      assert outcome.failure_class == "transient"
    end

    test "CH-9, CH-10: no reply after the end of data is uncertain within the call timeout",
         ctx do
      {:ok, port} = SmtpServer.start(mode: :implicit, tls: ctx.certs.server, hang: true)
      started = System.monotonic_time(:millisecond)

      assert {:uncertain, "timeout"} =
               Smtp.deliver(request(port, "implicit", ctx.pem, %{timeout_ms: 1_500}))

      assert System.monotonic_time(:millisecond) - started < 5_000
    end

    test "CH-10: a server that cannot be reached is not sent", ctx do
      assert {:not_sent, "connect_failed"} =
               Smtp.deliver(request(free_port(), "implicit", ctx.pem))
    end
  end

  describe "CH-38 CH-43 CH-44 CH-45 CH-76 the message" do
    test "CH-43, CH-44, CH-76: the sender's link reaches the recipient unchanged", ctx do
      {:ok, port} = SmtpServer.start(mode: :implicit, tls: ctx.certs.server)
      assert {:accepted, _info} = Smtp.deliver(request(port, "implicit", ctx.pem))

      leaves = session().data |> Mime.parse() |> Mime.leaves()
      bodies = Enum.map(leaves, fn {_type, part} -> Mime.decoded(part) end)
      assert Enum.any?(bodies, &String.contains?(&1, "Confirm: " <> @link))
      assert Enum.any?(bodies, &String.contains?(&1, ~s(href="#{@link}")))
      assert Enum.all?(bodies, &(length(String.split(&1, "https://")) <= 2))
    end

    test "CH-38: a bulk e-mail carries signed one-click unsubscribe fields", ctx do
      {:ok, port} = SmtpServer.start(mode: :implicit, tls: ctx.certs.server)

      content = %{
        "subject" => "News",
        "text" => "News inside",
        "category" => "newsletter",
        "unsubscribe" => %{
          "https" => "https://relay.example/u/opaque",
          "mailto" => "mailto:u-opaque@news.sender.example"
        }
      }

      request = request(port, "implicit", ctx.pem, %{class: "marketing", content: content})
      assert {:accepted, _info} = Smtp.deliver(request)

      data = session().data
      assert data =~ "List-Unsubscribe-Post: List-Unsubscribe=One-Click"
      assert data =~ "Feedback-ID: newsletter:newsletter:"
      assert :ok = Dkim.verify(data, public_key(request, "news.sender.example", "mk2026"))
      [_all, h] = Regex.run(~r/h=([^;]+);/, String.replace(data, ~r/\r\n[ \t]+/, " "))
      assert "list-unsubscribe" in String.split(String.replace(h, " ", ""), ":")
    end

    test "CH-38: a bulk e-mail without unsubscribe URIs is refused before any connection", ctx do
      content = %{"subject" => "News", "text" => "News inside"}
      overrides = %{class: "marketing", content: content}
      request = request(free_port(), "implicit", ctx.pem, overrides)
      assert {:rejected, %{code: "message_invalid"}} = Smtp.deliver(request)
    end

    test "CH-45: an internationalized address needs a server that supports SMTPUTF8", ctx do
      to = "reader@bücher.example"
      request = request(free_port(), "implicit", ctx.pem, %{to: to})
      assert {:rejected, %{code: "smtputf8_unsupported"}} = Smtp.deliver(request)

      {:ok, port} = SmtpServer.start(mode: :implicit, tls: ctx.certs.server)
      request = request(port, "implicit", ctx.pem, %{to: to, smtp: %{"smtputf8" => true}})
      assert {:accepted, _info} = Smtp.deliver(request)
      session = session()
      assert session.mail_from =~ ~r/> SMTPUTF8\z/
      assert session.rcpt_to == ["<" <> to <> ">"]
    end

    test "CH-35: the system class has no e-mail stream", ctx do
      request = request(free_port(), "implicit", ctx.pem, %{class: "system"})
      assert {:rejected, %{code: "message_invalid"}} = Smtp.deliver(request)
    end
  end
end
