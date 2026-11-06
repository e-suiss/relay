defmodule Relay.Channels.Smtp do
  @moduledoc """
  The "connect your own mail server" adapter (CH-34, CH-5): a tenant connects its own MTA (Postfix, KumoMTA, Exchange and the like) over standard SMTP, and Relay runs no MTA of its own. The message is the one `Relay.Channels.Email` builds and signs; this adapter only hands it to the server and reports the reply.

  TLS is always on and always verified (CH-34, T-39): TLS 1.2 or 1.3, `verify_peer` against the operating system's CA store or the account's own `ca_certificates`, SNI and the host name check of the server certificate. There are two modes, and no option to send in clear text or without verification:

    * `implicit`: TLS from the first byte, port 465 by default;
    * `starttls`: a plain connection upgraded with `STARTTLS` before anything else, port 587 by default; a server that does not offer `STARTTLS` is refused.

  The account's `settings` carry `"smtp"`: `"host"`, `"tls"` (`implicit` or `starttls`), and optionally `"port"`, `"helo"` (default: the sending domain), `"smtputf8"` (whether the server supports SMTPUTF8, default `false`, CH-45) and `"ca_certificates"` (PEM). The credential, when the account has one, is `{"username", "password"}`; the server must then offer authentication.

  The adapter never retries and never waits longer than the request's `timeout_ms` (CH-9, T-26). A failure before the message transaction is `:not_sent`; a connection lost or a timeout once the transaction started is `:uncertain`. A server reply is reported by its enhanced status code (`5.1.1`) or, without one, by its reply class (`smtp_4xx`, `smtp_5xx`); the adapter's errors map classifies it (CH-7).

  The settings check opens a session as a send does, connecting, greeting, upgrading to verified TLS and authenticating when the account has a credential, and ends it with `QUIT` before any message (CH-14, CH-52): a refused login is a credential mismatch; a server without `STARTTLS` or authentication, or a certificate that does not verify, is a mismatch of `tls` or `auth`; a lost connection or a server reply is an error.
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Email
  alias Relay.Channels.Email.StatusCode
  alias Relay.Channels.Request
  alias Relay.Channels.SettingsCheck
  alias Relay.Error

  @modes %{"implicit" => 465, "starttls" => 587}
  @refusals %{
    smtputf8_unsupported: "smtputf8_unsupported",
    invalid_email_content: "message_invalid",
    invalid_email_headers: "message_invalid",
    no_email_stream: "message_invalid",
    invalid_email_streams: "sender_invalid",
    dkim_header_missing: "message_invalid",
    dkim_key_too_short: "signing_key_invalid",
    key_not_found: "signing_key_invalid"
  }
  @unavailable [:key_store_unavailable, :key_store_timeout, :key_store_protocol]

  @type settings :: %{
          host: String.t(),
          port: 1..65_535,
          mode: String.t(),
          helo: String.t() | nil,
          smtputf8: boolean(),
          cacerts: [binary()] | nil
        }

  @impl Relay.Channels.Adapter
  def provider, do: "smtp"

  @impl Relay.Channels.Adapter
  def channels, do: ["email"]

  # CH-34
  # T-39
  @impl Relay.Channels.Adapter
  def deliver(%Request{} = request) do
    with {:ok, settings} <- settings(request.account),
         {:ok, auth} <- auth(request.credentials),
         {:ok, mail} <- Email.build(request, smtputf8: settings.smtputf8) do
      settings
      |> options(auth, mail.prepared)
      |> transmit(envelope(mail), request)
    else
      {:error, %Error{code: code}} when code in @unavailable ->
        {:not_sent, "key_store_unavailable"}

      {:error, %Error{} = error} ->
        {:rejected, refusal(error)}
    end
  end

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(%{"reply" => reply}) when is_binary(reply), do: reply(reply)
  def decode(%{"failure" => failure}) when is_binary(failure), do: %{code: failure, status: nil}

  # CH-14
  # CH-52
  # T-39
  @impl Relay.Channels.Adapter
  def check_settings(%{account: account, credentials: credentials, timeout_ms: timeout_ms}) do
    with {:settings, {:ok, settings}} <- {:settings, settings(account)},
         {:auth, {:ok, auth}} <- {:auth, auth(credentials)} do
      helo = List.first(SettingsCheck.stream_domains(account)) || "localhost"
      id = account["id"] || Relay.Id.generate()

      if Keyword.get(Logger.metadata(), :correlation_id) == nil,
        do: Logger.metadata(correlation_id: Relay.Id.to_string(id))

      settings
      |> options(auth, %{domain: helo})
      |> Keyword.put(:timeout, timeout_ms)
      |> session(timeout_ms)
    else
      {:settings, _invalid} -> SettingsCheck.mismatch("smtp", "valid", nil)
      {:auth, _invalid} -> SettingsCheck.credentials("invalid")
    end
  end

  defp session(options, timeout_ms) do
    task = Relay.Process.async(fn -> open(options) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> opened(result)
      {:exit, _reason} -> {:error, "smtp_session_failed"}
      nil -> {:error, "timeout"}
    end
  end

  defp open(options) do
    case :gen_smtp_client.open(options) do
      {:ok, socket} ->
        _ = :gen_smtp_client.close(socket)
        :opened

      failure ->
        failure
    end
  end

  defp opened(:opened), do: :ok

  defp opened({:error, _phase, {:permanent_failure, _host, :auth_failed}}),
    do: SettingsCheck.credentials("auth_failed")

  defp opened({:error, _phase, {:missing_requirement, _host, :auth}}),
    do: SettingsCheck.mismatch("auth", "offered", nil)

  defp opened({:error, _phase, {:missing_requirement, _host, :tls}}),
    do: SettingsCheck.mismatch("tls", "offered", nil)

  defp opened({:error, _phase, {:temporary_failure, _host, :tls_failed}}),
    do: SettingsCheck.mismatch("tls", "verified", "tls_failed")

  defp opened({:error, _phase, {:network_failure, _host, {:error, {:tls_alert, _alert}}}}),
    do: SettingsCheck.mismatch("tls", "verified", "tls_alert")

  defp opened({:error, _phase, {:network_failure, _host, _reason}}),
    do: {:error, "connect_failed"}

  defp opened({:error, _phase, {_kind, _host, reply}}) when is_binary(reply),
    do: {:error, reply(reply).code}

  defp opened(_other), do: {:error, "smtp_session_failed"}

  # CH-34
  # T-39
  @doc "Reads the `\"smtp\"` connection settings
 of an account; settings that allow no verified TLS connection are refused."
  @spec settings(map() | nil) :: {:ok, settings()} | {:error, Error.t()}
  def settings(%{"settings" => %{"smtp" => %{"host" => host, "tls" => mode} = smtp}})
      when is_binary(host) and is_map_key(@modes, mode) do
    port = Map.get(smtp, "port", Map.fetch!(@modes, mode))

    with :ok <- host(host),
         :ok <- port(port),
         {:ok, cacerts} <- cacerts(Map.get(smtp, "ca_certificates")) do
      {:ok,
       %{
         host: String.downcase(host, :ascii),
         port: port,
         mode: mode,
         helo: Map.get(smtp, "helo"),
         smtputf8: Map.get(smtp, "smtputf8") == true,
         cacerts: cacerts
       }}
    end
  end

  def settings(_account),
    do: invalid("the SMTP settings name a host and the TLS mode implicit or starttls")

  defp host(host) do
    if host =~ ~r/\A[a-z0-9](?:[a-z0-9.\-]{0,251}[a-z0-9])?\z/i and not ip?(host),
      do: :ok,
      else: invalid("the SMTP host is a DNS name, checked against the server certificate")
  end

  defp ip?(host), do: match?({:ok, _ip}, :inet.parse_address(String.to_charlist(host)))

  defp port(port) when is_integer(port) and port in 1..65_535, do: :ok
  defp port(_port), do: invalid("the SMTP port is between 1 and 65535")

  defp cacerts(nil), do: {:ok, nil}

  defp cacerts(pem) when is_binary(pem) do
    case for({:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der) do
      [] -> invalid("ca_certificates holds PEM certificates")
      ders -> {:ok, ders}
    end
  end

  defp cacerts(_pem), do: invalid("ca_certificates holds PEM certificates")

  defp auth(nil), do: {:ok, nil}

  defp auth(credentials) do
    case Relay.Redacted.expose(credentials) do
      %{"username" => user, "password" => password}
      when is_binary(user) and is_binary(password) ->
        {:ok, {user, password}}

      text when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, %{} = map} -> auth(Relay.Redacted.wrap(map))
          _other -> invalid("the SMTP credential is a username and a password")
        end

      _other ->
        invalid("the SMTP credential is a username and a password")
    end
  end

  # CH-34
  # T-39
  @doc "The TLS options of a connection to `host`: TLS 1.2 or 1.3, peer verification against `cacerts` (the operating system's store when `nil`), SNI and the HTTPS host name check."
  @spec tls_options(String.t(), [binary()] | nil) :: keyword()
  def tls_options(host, cacerts) do
    [
      versions: [:"tlsv1.3", :"tlsv1.2"],
      verify: :verify_peer,
      cacerts: cacerts || :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      depth: 10,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp options(settings, auth, prepared) do
    tls = tls_options(settings.host, settings.cacerts)

    mode =
      case settings.mode do
        "implicit" -> [ssl: true, tls: :never, sockopts: tls]
        "starttls" -> [ssl: false, tls: :always, tls_options: tls]
      end

    credentials =
      case auth do
        nil ->
          [auth: :never]

        {user, password} ->
          [
            auth: :always,
            username: String.to_charlist(user),
            password: String.to_charlist(password)
          ]
      end

    [
      relay: String.to_charlist(settings.host),
      port: settings.port,
      hostname: String.to_charlist(settings.helo || prepared.domain),
      retries: 0,
      no_mx_lookups: true,
      on_transaction_error: :quit
    ] ++ mode ++ credentials
  end

  defp envelope(%{prepared: prepared, data: data}) do
    from = "<" <> prepared.return_path <> ">"
    from = if prepared.smtputf8, do: from <> " SMTPUTF8", else: from
    {from, [prepared.to], data}
  end

  # CH-9
  # T-26
  defp transmit(options, envelope, %Request{timeout_ms: timeout_ms} = request) do
    options = Keyword.put(options, :timeout, timeout_ms)

    if Keyword.get(Logger.metadata(), :correlation_id) == nil,
      do: Logger.metadata(correlation_id: Relay.Id.to_string(request.delivery_id))

    task = Relay.Process.async(fn -> :gen_smtp_client.send_blocking(envelope, options) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result(result)
      {:exit, _reason} -> {:uncertain, "smtp_session_failed"}
      nil -> {:uncertain, "timeout"}
    end
  end

  # CH-7
  # CH-10
  # T-28
  defp result(receipt) when is_binary(receipt),
    do: {:accepted, %{provider_message_id: receipt(receipt), delivery_rank: :accepted}}

  defp result({:error, :send, {:network_failure, _host, _reason}}),
    do: {:uncertain, "connection_lost"}

  defp result({:error, :send, {_kind, _host, reply}}) when is_binary(reply),
    do: {:rejected, reply(reply)}

  defp result({:error, _phase, {:network_failure, _host, {:error, {:tls_alert, _alert}}}}),
    do: {:rejected, %{code: "tls_failed", status: nil}}

  defp result({:error, _phase, {:network_failure, _host, _reason}}),
    do: {:not_sent, "connect_failed"}

  defp result({:error, _phase, {:temporary_failure, _host, :tls_failed}}),
    do: {:rejected, %{code: "tls_failed", status: nil}}

  defp result({:error, _phase, {:missing_requirement, _host, :tls}}),
    do: {:rejected, %{code: "tls_unavailable", status: nil}}

  defp result({:error, _phase, {:missing_requirement, _host, :auth}}),
    do: {:rejected, %{code: "auth_unavailable", status: nil}}

  defp result({:error, _phase, {:permanent_failure, _host, :auth_failed}}),
    do: {:rejected, %{code: "auth_failed", status: nil}}

  defp result({:error, _phase, {_kind, _host, reply}}) when is_binary(reply),
    do: {:rejected, reply(reply)}

  defp result({:error, reason}) when is_atom(reason),
    do: {:rejected, %{code: "configuration_invalid", status: nil}}

  defp result(_other), do: {:uncertain, "smtp_session_failed"}

  defp reply(reply) do
    status =
      case StatusCode.reply_code(reply) do
        {:ok, code} -> code
        :error -> nil
      end

    code =
      case {StatusCode.find(reply), status} do
        {{:ok, enhanced}, _status} -> StatusCode.to_string(enhanced)
        {:error, status} when status in 400..499 -> "smtp_4xx"
        {:error, _status} -> "smtp_5xx"
      end

    %{code: code, status: status, detail: %{"reply" => String.slice(String.trim(reply), 0, 512)}}
  end

  defp receipt(receipt) do
    case receipt |> String.trim() |> String.slice(0, 256) do
      "" -> nil
      text -> text
    end
  end

  defp refusal(%Error{code: code}), do: %{code: Map.get(@refusals, code, "configuration_invalid")}

  defp invalid(message), do: {:error, Error.new(:invalid_smtp_settings, message)}
end
