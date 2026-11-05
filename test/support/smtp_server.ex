defmodule RelayTest.SmtpServer do
  @moduledoc """
  An in-process SMTP server for adapter tests, with no network beyond the loopback interface. It serves one session on `127.0.0.1` in `:implicit` TLS, `:starttls` or `:plain` mode with a certificate made by `certificates/1`, answers with scripted replies and sends the session to its owner as `{:smtp_session, session}` when the client quits or the connection ends.
  """

  @type session :: %{
          tls: boolean(),
          helo: String.t() | nil,
          auth: String.t() | nil,
          mail_from: String.t() | nil,
          rcpt_to: [String.t()],
          data: binary() | nil
        }

  @doc "A test certificate chain: `:server` holds the server's `:cert`, `:key` and chain options for a peer certificate whose subject alternative name is `host`, `:cacerts` the root a client trusts."
  @spec certificates(String.t()) :: %{server: keyword(), cacerts: [binary()]}
  def certificates(host \\ "localhost") do
    san = {:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(host)}]}
    key = {:rsa, 2048, 65_537}

    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: [key: key], intermediates: [], peer: [key: key, extensions: [san]]},
        client_chain: %{root: [key: key], intermediates: [], peer: [key: key]}
      })

    %{server: server, cacerts: Keyword.fetch!(client, :cacerts)}
  end

  @doc """
  Starts a server and returns its port. Options: `:mode` (`:implicit`, `:starttls` or `:plain`), `:tls` (the server options of `certificates/1`), `:starttls` (whether `STARTTLS` is offered, default true outside `:plain`), `:auth` (whether `AUTH PLAIN` is offered), `:greeting`, `:mail`, `:rcpt` and `:data` (the replies), `:hang` (no reply after the end of data), and `:owner`, the process that receives the session.
  """
  @spec start(keyword()) :: {:ok, :inet.port_number()}
  def start(opts) do
    owner = Keyword.get(opts, :owner, self())
    mode = Keyword.fetch!(opts, :mode)
    parent = self()

    {:ok, pid} =
      Task.start_link(fn ->
        {listen, port} = listen(mode, opts)
        send(parent, {:smtp_port, self(), port})
        serve(accept(mode, listen, opts), mode, opts, owner)
      end)

    receive do
      {:smtp_port, ^pid, port} -> {:ok, port}
    after
      5_000 -> raise "the SMTP server did not start"
    end
  end

  @base [:binary, packet: :line, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]

  defp listen(:implicit, opts) do
    {:ok, listen} = :ssl.listen(0, @base ++ Keyword.fetch!(opts, :tls))
    {:ok, {_ip, port}} = :ssl.sockname(listen)
    {listen, port}
  end

  defp listen(_mode, _opts) do
    {:ok, listen} = :gen_tcp.listen(0, @base)
    {:ok, port} = :inet.port(listen)
    {listen, port}
  end

  defp accept(:implicit, listen, _opts) do
    {:ok, transport} = :ssl.transport_accept(listen, 10_000)

    case :ssl.handshake(transport, 10_000) do
      {:ok, socket} -> {:ssl, socket}
      {:error, _reason} -> :closed
    end
  end

  defp accept(_mode, listen, _opts) do
    {:ok, socket} = :gen_tcp.accept(listen, 10_000)
    {:tcp, socket}
  end

  defp serve(:closed, _mode, _opts, owner), do: send(owner, {:smtp_session, :handshake_failed})

  defp serve(socket, mode, opts, owner) do
    session = %{
      tls: mode == :implicit,
      helo: nil,
      auth: nil,
      mail_from: nil,
      rcpt_to: [],
      data: nil
    }

    reply(socket, Keyword.get(opts, :greeting, "220 localhost ESMTP test"))
    loop(socket, session, mode, opts, owner)
  end

  defp loop(socket, session, mode, opts, owner) do
    case recv(socket) do
      {:ok, line} -> command(socket, String.trim_trailing(line), session, mode, opts, owner)
      {:error, _closed} -> send(owner, {:smtp_session, session})
    end
  end

  defp command(socket, line, session, mode, opts, owner) do
    case String.upcase(String.slice(line, 0, 4)) do
      "EHLO" ->
        ehlo(socket, session, mode, opts)
        loop(socket, %{session | helo: String.slice(line, 5..-1//1)}, mode, opts, owner)

      "STAR" ->
        reply(socket, "220 2.0.0 ready to start TLS")
        {:tcp, tcp} = socket

        case :ssl.handshake(tcp, Keyword.fetch!(opts, :tls), 10_000) do
          {:ok, tls} -> loop({:ssl, tls}, %{session | tls: true}, mode, opts, owner)
          {:error, _reason} -> send(owner, {:smtp_session, :handshake_failed})
        end

      "AUTH" ->
        reply(socket, "235 2.7.0 authenticated")
        loop(socket, %{session | auth: line}, mode, opts, owner)

      "MAIL" ->
        reply(socket, Keyword.get(opts, :mail, "250 2.1.0 ok"))
        loop(socket, %{session | mail_from: String.slice(line, 10..-1//1)}, mode, opts, owner)

      "RCPT" ->
        reply(socket, Keyword.get(opts, :rcpt, "250 2.1.5 ok"))
        to = String.slice(line, 8..-1//1)
        loop(socket, %{session | rcpt_to: session.rcpt_to ++ [to]}, mode, opts, owner)

      "DATA" ->
        reply(socket, "354 go ahead")
        data = data(socket, [])
        session = %{session | data: data}

        if Keyword.get(opts, :hang, false) do
          send(owner, {:smtp_session, session})
          Process.sleep(:infinity)
        else
          reply(socket, Keyword.get(opts, :data, "250 2.0.0 Ok: queued as Q1"))
          loop(socket, session, mode, opts, owner)
        end

      "RSET" ->
        reply(socket, "250 2.0.0 ok")
        loop(socket, session, mode, opts, owner)

      "QUIT" ->
        reply(socket, "221 2.0.0 bye")
        close(socket)
        send(owner, {:smtp_session, session})

      _other ->
        reply(socket, "502 5.5.2 not implemented")
        loop(socket, session, mode, opts, owner)
    end
  end

  defp ehlo(socket, session, mode, opts) do
    starttls = mode != :plain and Keyword.get(opts, :starttls, true) and not session.tls
    auth = Keyword.get(opts, :auth, false)

    lines =
      ["localhost", "8BITMIME", "SMTPUTF8"] ++
        if(starttls, do: ["STARTTLS"], else: []) ++ if(auth, do: ["AUTH PLAIN"], else: [])

    {init, [last]} = Enum.split(lines, -1)
    text = Enum.map_join(init, &("250-" <> &1 <> "\r\n")) <> "250 " <> last
    reply(socket, text)
  end

  defp data(socket, acc) do
    case recv(socket) do
      {:ok, ".\r\n"} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      {:ok, "." <> rest} -> data(socket, [rest | acc])
      {:ok, line} -> data(socket, [line | acc])
      {:error, _closed} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp reply(socket, text), do: transmit(socket, text <> "\r\n")

  defp transmit({:tcp, socket}, data), do: :gen_tcp.send(socket, data)
  defp transmit({:ssl, socket}, data), do: :ssl.send(socket, data)

  defp recv({:tcp, socket}), do: :gen_tcp.recv(socket, 0, 10_000)
  defp recv({:ssl, socket}), do: :ssl.recv(socket, 0, 10_000)

  defp close({:tcp, socket}), do: :gen_tcp.close(socket)
  defp close({:ssl, socket}), do: :ssl.close(socket)
end
