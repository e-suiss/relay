defmodule Relay.Channels.Email do
  @moduledoc """
  The outgoing e-mail of a delivery, built once for every e-mail adapter so the SMTP adapter and the ESP adapters carry the same sender, header fields, return path and signature (CH-34, CH-35, CH-38, CH-43, CH-44, CH-45, CH-76).

    * The sender identity is the stream configuration of the provider account (`Relay.Channels.Email.Streams`): the request's `sender` when the route gives one, otherwise the account's `settings`, read by the message class and the content's optional `"category"`. The `system` class has no e-mail stream. The delivery's `overrides.email.from` (`Request` `overrides`), checked against the verified sender identities at intake and again by the channel step, replaces the stream's from address; the sending domain, DKIM selector and return path stay the stream's (API-23).
    * The header fields are those of `Relay.Channels.Email.Headers`: `Feedback-ID` (`<campaign>:<category>:<tenant>:<sender>`) on every e-mail, and on a bulk one `List-Unsubscribe` and `List-Unsubscribe-Post` from the content's `"unsubscribe"` (`"https"` and `"mailto"`); a bulk e-mail without them is refused.
    * The envelope sender is the VERP return path of the delivery under the stream's return path domain (`Relay.Channels.Email.Verp`), its tag computed inside the key store under the tenant environment's VERP key (`verp_key_label/1`).
    * The subject, plain text and HTML are passed as the renderer wrote them unless the request's `tracking` plan turns on link wrapping or the open pixel, which only the tenant does for a category or template (`Relay.Channels.Email.Tracking`, CH-43, DS-29): then the HTML part's links lead through Relay's click endpoint and an open pixel is appended, signed under the tenant environment's tracking key (`tracking_key_label/1`). Without a plan a link the sender wrote, Access's `email_verification` link among them, reaches the recipient unchanged, and a `security` e-mail never has tracking or a redirect chain.
    * An address that needs SMTPUTF8 is never refused: the message is marked for it, and a provider without support fails with the `permanent_content` error `smtputf8_unsupported`.
    * `render/2` writes the message with Swoosh and signs it with DKIM (`Relay.Channels.Email.Dkim`) inside the key store under the key of the stream's domain and selector (`dkim_key_label/3`); every field Relay adds is inside `h=`.
  """

  alias Relay.Channels.Email.Dkim
  alias Relay.Channels.Email.Headers
  alias Relay.Channels.Email.Mime
  alias Relay.Channels.Email.Smtputf8
  alias Relay.Channels.Email.Streams
  alias Relay.Channels.Email.Tracking
  alias Relay.Channels.Email.Verp
  alias Relay.Channels.Request
  alias Relay.Error
  alias Relay.Scope

  @feedback_part ~r/\A[A-Za-z0-9._\-]{1,64}\z/

  @type prepared :: %{
          stream: String.t(),
          from: String.t(),
          from_name: String.t() | nil,
          reply_to: String.t() | nil,
          to: String.t(),
          subject: String.t(),
          text: String.t(),
          html: String.t() | nil,
          headers: [{String.t(), String.t()}],
          dkim_headers: [String.t()],
          return_path: String.t(),
          message_id: String.t(),
          date: DateTime.t(),
          domain: String.t(),
          selector: String.t(),
          ip_pool: String.t() | nil,
          queue: String.t() | nil,
          smtputf8: boolean()
        }

  @type built :: %{prepared: prepared(), data: binary()}

  # CH-36
  # TN-63
  @doc "The key store label of the DKIM key of a tenant environment's sending domain and selector."
  @spec dkim_key_label(Scope.t(), String.t(), String.t()) :: Relay.Keys.label()
  def dkim_key_label(%Scope{} = scope, domain, selector)
      when is_binary(domain) and is_binary(selector) do
    Enum.join(
      [
        "relay-dkim",
        Relay.Id.to_string(scope.tenant_id),
        Relay.Environment.dump(scope.environment),
        String.downcase(domain, :ascii),
        selector
      ],
      "/"
    )
  end

  # CH-38
  # TN-63
  @doc "The key store label of the VERP key of a tenant environment."
  @spec verp_key_label(Scope.t()) :: Relay.Keys.label()
  def verp_key_label(%Scope{} = scope) do
    Enum.join(
      [
        "relay-verp",
        Relay.Id.to_string(scope.tenant_id),
        Relay.Environment.dump(scope.environment)
      ],
      "/"
    )
  end

  # CH-43
  # TN-63
  @doc "The key store label of the open and click tracking key of a tenant environment."
  @spec tracking_key_label(Scope.t()) :: Relay.Keys.label()
  def tracking_key_label(%Scope{} = scope) do
    Enum.join(
      [
        "relay-tracking",
        Relay.Id.to_string(scope.tenant_id),
        Relay.Environment.dump(scope.environment)
      ],
      "/"
    )
  end

  # CH-43
  @doc "Relay's public root, where the tracking endpoints are served: the scheme, host and port of the endpoint's configured URL."
  @spec public_root() :: String.t()
  def public_root do
    url = :relay |> Application.get_env(RelayWeb.Endpoint, []) |> Keyword.get(:url, [])
    scheme = Keyword.get(url, :scheme, "https")
    port = Keyword.get(url, :port)
    default? = port == nil or {scheme, port} in [{"https", 443}, {"http", 80}]
    root = scheme <> "://" <> Keyword.get(url, :host, "localhost")
    if default?, do: root, else: root <> ":" <> Integer.to_string(port)
  end

  # CH-35
  # CH-38
  # CH-43
  # CH-45
  @doc """
  Prepares the e-mail of a request: the sender identity of its stream, the recipient, the rendered parts (with the request's tracking plan applied to the HTML part), the header fields, the VERP return path and the `Message-ID`. `opts` takes `:smtputf8`, whether the provider supports SMTPUTF8 (default `false`), `:mac`, the VERP key function (default: the tenant environment's VERP key in the key store), `:tracking_mac`, the tracking key function (default: the tenant environment's tracking key), and `:tracking_root` (default `public_root/0`).
  """
  @spec prepare(Request.t(), keyword()) :: {:ok, prepared()} | {:error, Error.t()}
  def prepare(%Request{} = request, opts \\ []) do
    content = content(request.content)
    class = request.message_class || ""
    mac = Keyword.get_lazy(opts, :mac, fn -> verp_mac(request.scope) end)

    with {:ok, sender} <- sender(config(request), class, text(content, "category")),
         sender = from_override(sender, request),
         {:ok, parts} <- parts(content),
         {:ok, html} <- tracked(request, parts.html, opts),
         parts = %{parts | html: html},
         {:ok, to} <- recipient(request),
         {:ok, return_path} <- Verp.encode(request.delivery_id, sender.return_path_domain, mac),
         {:ok, headers} <- headers(request, class, content, return_path),
         {:ok, smtputf8} <-
           Smtputf8.check([sender.from, to, return_path], Keyword.get(opts, :smtputf8, false)) do
      {:ok,
       Map.merge(parts, %{
         stream: sender.stream,
         from: sender.from,
         from_name: text(config(request), "from_name"),
         reply_to: text(config(request), "reply_to"),
         to: to,
         headers: headers.headers,
         dkim_headers: headers.dkim_headers,
         return_path: return_path,
         message_id: message_id(request.delivery_id, sender.domain),
         date: Relay.Clock.utc_now(),
         domain: sender.domain,
         selector: sender.selector,
         ip_pool: sender.ip_pool,
         queue: sender.queue,
         smtputf8: smtputf8
       })}
    end
  end

  # CH-87
  @doc "The sending domain of a request's e-mail: the domain of its stream's sender identity, by the message class and the content's optional `\"category\"`; `:error` when the stream names none."
  @spec sending_domain(Request.t()) :: {:ok, String.t()} | :error
  def sending_domain(%Request{} = request) do
    category = text(content(request.content), "category")

    case sender(config(request), request.message_class || "", category) do
      {:ok, %{domain: domain}} -> {:ok, String.downcase(domain, :ascii)}
      {:error, _error} -> :error
    end
  end

  # CH-44
  # DS-29
  defp tracked(%Request{message_class: "security"}, html, _opts), do: {:ok, html}

  defp tracked(%Request{tracking: %{} = plan} = request, html, opts) do
    root = Keyword.get_lazy(opts, :tracking_root, &public_root/0)
    label = tracking_key_label(request.scope)
    mac = Keyword.get_lazy(opts, :tracking_mac, fn -> Verp.key_function(label) end)
    Tracking.instrument(html, plan, {request.scope, request.delivery_id}, {root, mac})
  end

  defp tracked(_request, html, _opts), do: {:ok, html}

  # API-23
  defp from_override(sender, %Request{overrides: %{"from" => from}})
       when is_binary(from) and from != "",
       do: %{sender | from: from}

  defp from_override(sender, _request), do: sender

  defp verp_mac(scope), do: Verp.key_function(verp_key_label(scope))

  defp message_id(delivery_id, domain),
    do: "<" <> Relay.Id.to_string(delivery_id) <> "@" <> domain <> ">"

  # CH-36
  # CH-38
  @doc "Prepares, renders and signs the e-mail of a request; see `prepare/2` and `render/2`. `opts` also takes `:signer`, the DKIM signer (default: the key of the stream's domain and selector in the key store)."
  @spec build(Request.t(), keyword()) :: {:ok, built()} | {:error, Error.t()}
  def build(%Request{} = request, opts \\ []) do
    with {:ok, prepared} <- prepare(request, opts),
         {:ok, signer} <- signer(request, prepared, opts),
         {:ok, data} <- render(prepared, signer) do
      {:ok, %{prepared: prepared, data: data}}
    end
  end

  defp signer(request, prepared, opts) do
    case Keyword.fetch(opts, :signer) do
      {:ok, signer} ->
        {:ok, signer}

      :error ->
        Dkim.key_signer(dkim_key_label(request.scope, prepared.domain, prepared.selector))
    end
  end

  # CH-36
  # CH-38
  @doc "Writes a prepared e-mail as a MIME message with CRLF line endings and puts its `DKIM-Signature` field first, signed by `signer` over the fields Relay adds and the body."
  @spec render(prepared(), Dkim.signer()) :: {:ok, binary()} | {:error, Error.t()}
  def render(prepared, signer) when is_function(signer, 1) do
    params = %{
      domain: prepared.domain,
      selector: prepared.selector,
      timestamp: DateTime.to_unix(prepared.date),
      required: prepared.dkim_headers
    }

    with {:ok, message} <- mime(prepared),
         {:ok, field} <- Dkim.sign(message, params, signer),
         do: {:ok, field <> "\r\n" <> message}
  end

  # CH-38
  @doc "Writes a prepared e-mail as an unsigned MIME message with CRLF line endings, for a provider that signs it itself."
  @spec mime(prepared()) :: {:ok, binary()} | {:error, Error.t()}
  def mime(prepared) do
    {:ok, prepared |> swoosh() |> Swoosh.Adapters.SMTP.Helpers.body([]) |> Mime.crlf()}
  rescue
    _error -> invalid(:invalid_email_content, "the e-mail cannot be written as MIME")
  end

  defp swoosh(prepared) do
    email =
      Swoosh.Email.new()
      |> Swoosh.Email.from({prepared.from_name || "", prepared.from})
      |> Swoosh.Email.to(prepared.to)
      |> Swoosh.Email.subject(prepared.subject)
      |> Swoosh.Email.text_body(prepared.text)
      |> Swoosh.Email.header("Date", date(prepared.date))
      |> Swoosh.Email.header("Message-ID", prepared.message_id)

    email = if prepared.html, do: Swoosh.Email.html_body(email, prepared.html), else: email

    email = if prepared.reply_to, do: Swoosh.Email.reply_to(email, prepared.reply_to), else: email

    Enum.reduce(prepared.headers, email, fn {name, value}, acc ->
      Swoosh.Email.header(acc, name, value)
    end)
  end

  defp date(%DateTime{} = date) do
    date |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%a, %d %b %Y %H:%M:%S +0000")
  end

  defp config(%Request{sender: %{"streams" => _} = sender}), do: sender

  defp config(%Request{account: %{"settings" => %{"streams" => _} = settings}}), do: settings

  defp config(_request), do: %{"streams" => %{}}

  defp sender(config, class, category) do
    with {:ok, stream} <- Streams.stream(class),
         %{"streams" => %{^stream => %{}}} <- config,
         {:ok, sender} <- Streams.sender(config, class, category),
         fields = [sender.from, sender.domain, sender.selector, sender.return_path_domain],
         true <- Enum.all?(fields, &(is_binary(&1) and &1 != "")) do
      {:ok, sender}
    else
      {:error, %Error{}} = error -> error
      _incomplete -> invalid(:invalid_email_streams, "the stream names its sender identity")
    end
  end

  defp content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{} = decoded} -> decoded
      _other -> %{}
    end
  end

  defp content(%{} = content), do: content
  defp content(_content), do: %{}

  defp parts(content) do
    case {text(content, "subject"), text(content, "text"), text(content, "html")} do
      {subject, text, html} when is_binary(subject) and is_binary(text) ->
        {:ok, %{subject: subject, text: text, html: html}}

      _missing ->
        invalid(:invalid_email_content, "an e-mail has a subject and a plain text body")
    end
  end

  defp recipient(%Request{target: %{value: value}}) do
    case Relay.Redacted.expose(value) do
      address when is_binary(address) and address != "" -> {:ok, address}
      _other -> invalid(:invalid_email_content, "an e-mail has a recipient address")
    end
  end

  defp headers(request, class, content, return_path) do
    category = text(content, "category") || class
    campaign = text(content, "campaign") || category

    Headers.build(%{
      class: class,
      return_path: return_path,
      feedback_id: %{
        campaign: part(campaign),
        category: part(category),
        tenant: Relay.Id.to_string(request.scope.tenant_id),
        sender: part(sender_ref(request))
      },
      unsubscribe: unsubscribe(content)
    })
  end

  defp sender_ref(%Request{account: %{"id" => <<_::128>> = id}}), do: Relay.Id.to_string(id)
  defp sender_ref(%Request{provider: provider}), do: provider

  defp part(value) do
    if Regex.match?(@feedback_part, value),
      do: value,
      else: value |> String.replace(~r/[^A-Za-z0-9._\-]/, "_") |> String.slice(0, 64)
  end

  defp unsubscribe(%{"unsubscribe" => %{"https" => https, "mailto" => mailto}})
       when is_binary(https) and is_binary(mailto),
       do: %{https: https, mailto: mailto}

  defp unsubscribe(_content), do: nil

  defp text(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp invalid(code, message), do: {:error, Error.new(code, message)}
end
