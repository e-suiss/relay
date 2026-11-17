defmodule Relay.Agents.Message do
  @moduledoc """
  The structured message an agent receives (MD-11, C-76, INV-30, E-71, TP-44, AG-39, AG-40). What reaches an agent is never a prompt: control information is in typed fields that Relay produces, content is data in parts, and Relay writes no free text of its own to an agent. The module is pure.

  `prepare/2` turns what a sender handed in into the stored content of a mailbox record. The control fields of the input (the sender's kind and identifier, the channel, the relation of a link) are identifiers of a fixed syntax, and an input that puts anything else there is refused. Every part a sender supplies is untrusted: a text part is normalised to visible text (`Relay.Agents.UntrustedContent`), the strings of a data part likewise. A link is kept only when it is `https` and its origin is on the tenant's allow list; any other link is withheld and counted. Content over `x-relay-limits` `mailbox.message.max_bytes` moves its largest texts out of the record's payload to the referenced content, which also keeps the raw form of every text the normalisation changed; referenced content is read by a separate reference.

  `message_data/4` and `waitpoint_data/2` build the typed data of a record, and `envelope/2` the CloudEvents 1.0 envelope around it, which is only the outer envelope. A part has the A2A shape (`kind` `text` or `data`, `mediaType`) with its `audience`, the counterpart of MCP `annotations.audience`. An untrusted text stands between its boundary marks with a value drawn for the part, which the typed field `untrusted.nonce` repeats beside the source of the text: its author, whether the author is verified and the channel. A response token, a response link and a waitpoint credential are no field of a message (E-71, AG-30).
  """

  alias Relay.Agents.UntrustedContent

  @limits Relay.Limits.fetch!(["mailbox", "message"])
  @max_bytes Map.fetch!(@limits, "max_bytes")
  @referenced_max_bytes Map.fetch!(@limits, "referenced_max_bytes")
  @max_parts Map.fetch!(@limits, "max_parts")
  @max_links Map.fetch!(@limits, "max_links")
  @sender_kinds %{human: "human", system: "system", agent: "agent"}
  @audiences %{user: "user", assistant: "assistant"}
  @identifier ~r/\A[A-Za-z0-9][A-Za-z0-9._:@\/+=-]{0,255}\z/
  @channel ~r/\A[a-z][a-z_]{0,31}\z/
  @relation ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @result ~r/\A[a-z][a-z_]{0,31}\z/

  @type issue :: %{field: String.t(), code: String.t()}
  @type too_large :: %{limit_name: String.t(), limit: pos_integer(), actual: pos_integer()}
  @type prepared :: %{
          payload: binary(),
          referenced: binary() | nil,
          digest: <<_::256>>,
          links_withheld: non_neg_integer()
        }
  @type include :: :inline | :referenced

  # AG-53
  # AG-70
  @doc "The limits of a message as the contract publishes them."
  @spec limits() :: %{
          max_bytes: pos_integer(),
          referenced_max_bytes: pos_integer(),
          max_parts: pos_integer(),
          max_links: pos_integer()
        }
  def limits do
    %{
      max_bytes: @max_bytes,
      referenced_max_bytes: @referenced_max_bytes,
      max_parts: @max_parts,
      max_links: @max_links
    }
  end

  # INV-30
  # AG-39
  # AG-40
  # AG-41
  # AG-70
  @doc """
  The stored content of a message from what its sender handed in. `input` carries `:sender` (`:kind` `:human`, `:system` or `:agent` and `:id`), `:channel`, optional `:subject_digest` (32 bytes), `:parts` (`%{kind: :text, text: text, format: :plain | :html}` or `%{kind: :data, data: map}`, each with an optional `:audience` of `:user` and `:assistant`) and optional `:links` (`:rel` and `:href`). `origins` is the tenant's link allow list.

  Returns the payload and the referenced content as JSON, the digest of the payload and the number of links withheld; `{:error, {:invalid, issues}}` when a control field or a part breaks its rule, and `{:error, {:too_large, limit}}` when the content does not fit its limits.
  """
  @spec prepare(map(), [String.t()]) ::
          {:ok, prepared()} | {:error, {:invalid, [issue(), ...]} | {:too_large, too_large()}}
  def prepare(input, origins) when is_map(input) and is_list(origins) do
    checked = [
      sender(Map.get(input, :sender)),
      channel(Map.get(input, :channel)),
      subject_digest(Map.get(input, :subject_digest)),
      parts(Map.get(input, :parts)),
      links(Map.get(input, :links, []))
    ]

    case for({:error, issues} <- checked, issue <- issues, do: issue) do
      [] ->
        [sender, channel, digest, parts, links] = for {:ok, value} <- checked, do: value
        {allowed, withheld} = Enum.split_with(links, &allowed?(&1, origins))

        fit(
          %{
            "v" => 1,
            "sender" => sender,
            "channel" => channel,
            "subject_digest" => digest,
            "links" => allowed,
            "links_withheld" => length(withheld)
          },
          parts
        )

      issues ->
        {:error, {:invalid, issues}}
    end
  end

  defp sender(%{kind: kind, id: id}) when is_map_key(@sender_kinds, kind) and is_binary(id) do
    if Regex.match?(@identifier, id),
      do: {:ok, %{"kind" => Map.fetch!(@sender_kinds, kind), "id" => id}},
      else: issue("sender.id", "invalid_format")
  end

  defp sender(_other), do: issue("sender", "invalid_format")

  defp channel(channel) when is_binary(channel) do
    if Regex.match?(@channel, channel),
      do: {:ok, channel},
      else: issue("channel", "invalid_format")
  end

  defp channel(_other), do: issue("channel", "invalid_format")

  defp subject_digest(nil), do: {:ok, nil}
  defp subject_digest(<<_::256>> = digest), do: {:ok, digest_text(digest)}
  defp subject_digest(_other), do: issue("subject_digest", "invalid_format")

  defp issue(field, code), do: {:error, [%{field: field, code: code}]}

  defp parts(parts) when is_list(parts) and length(parts) <= @max_parts do
    prepared = parts |> Enum.with_index() |> Enum.map(fn {part, at} -> part(part, at) end)

    case for({:error, issues} <- prepared, issue <- issues, do: issue) do
      [] -> {:ok, for({:ok, part} <- prepared, do: part)}
      issues -> {:error, issues}
    end
  end

  defp parts(parts) when is_list(parts), do: issue("parts", "too_many")
  defp parts(_other), do: issue("parts", "invalid_format")

  defp part(%{kind: :text, text: text} = part, at) when is_binary(text) do
    format = Map.get(part, :format, :plain)

    with {:ok, audience} <- audience(Map.get(part, :audience), at),
         :ok <- text_format(format, text, at) do
      visible = UntrustedContent.normalise(text, format)

      stored = %{
        "kind" => "text",
        "media_type" => "text/plain",
        "audience" => audience,
        "text" => visible,
        "text_bytes" => byte_size(visible),
        "raw_bytes" => if(visible == text, do: nil, else: byte_size(text)),
        "raw_media_type" => if(format == :html, do: "text/html", else: "text/plain")
      }

      {:ok, {stored, if(visible == text, do: nil, else: text)}}
    end
  end

  defp part(%{kind: :data, data: data} = part, at) when is_map(data) do
    with {:ok, audience} <- audience(Map.get(part, :audience), at),
         {:ok, visible} <- data(data, at) do
      stored = %{
        "kind" => "data",
        "media_type" => "application/json",
        "audience" => audience,
        "data" => visible
      }

      {:ok, {stored, nil}}
    end
  end

  defp part(_other, at), do: issue("parts.#{at}", "invalid_format")

  defp text_format(format, text, at) do
    cond do
      format not in [:plain, :html] -> issue("parts.#{at}.format", "invalid_format")
      not String.valid?(text) -> issue("parts.#{at}.text", "invalid_encoding")
      true -> :ok
    end
  end

  defp audience(nil, _at), do: {:ok, ["user", "assistant"]}

  defp audience([_ | _] = audience, at) do
    if Enum.all?(audience, &is_map_key(@audiences, &1)),
      do: {:ok, audience |> Enum.uniq() |> Enum.map(&Map.fetch!(@audiences, &1))},
      else: issue("parts.#{at}.audience", "invalid_format")
  end

  defp audience(_other, at), do: issue("parts.#{at}.audience", "invalid_format")

  defp data(data, at) do
    case plain(data) do
      {:ok, visible} -> {:ok, visible}
      :error -> issue("parts.#{at}.data", "invalid_format")
    end
  end

  defp plain(text) when is_binary(text) do
    if String.valid?(text), do: {:ok, UntrustedContent.normalise(text, :plain)}, else: :error
  end

  defp plain(value) when is_number(value) or is_boolean(value) or is_nil(value), do: {:ok, value}

  defp plain(list) when is_list(list) do
    reduced =
      Enum.reduce_while(list, {:ok, []}, fn item, {:ok, done} ->
        case plain(item) do
          {:ok, value} -> {:cont, {:ok, [value | done]}}
          :error -> {:halt, :error}
        end
      end)

    with {:ok, done} <- reduced, do: {:ok, Enum.reverse(done)}
  end

  defp plain(map) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, item}, {:ok, done} ->
      with true <- is_binary(key),
           {:ok, name} <- plain(key),
           {:ok, value} <- plain(item) do
        {:cont, {:ok, Map.put(done, name, value)}}
      else
        _invalid -> {:halt, :error}
      end
    end)
  end

  defp plain(_other), do: :error

  defp links(links) when is_list(links) and length(links) <= @max_links do
    checked = links |> Enum.with_index() |> Enum.map(fn {link, at} -> link(link, at) end)

    case for({:error, issues} <- checked, issue <- issues, do: issue) do
      [] -> {:ok, for({:ok, link} <- checked, do: link)}
      issues -> {:error, issues}
    end
  end

  defp links(links) when is_list(links), do: issue("links", "too_many")
  defp links(_other), do: issue("links", "invalid_format")

  defp link(%{rel: relation, href: href}, at) when is_binary(relation) and is_binary(href) do
    if Regex.match?(@relation, relation),
      do: {:ok, %{"rel" => relation, "href" => href}},
      else: issue("links.#{at}.rel", "invalid_format")
  end

  defp link(_other, at), do: issue("links.#{at}", "invalid_format")

  # AG-40
  # AG-41
  @doc "The origin of an `https` link, `https://` with the lowercase host and a port other than 443, or `nil` for anything that is no such link: another scheme, user information, no host or a text that is not a URL."
  @spec origin(term()) :: String.t() | nil
  def origin(href) when is_binary(href) do
    with true <- String.valid?(href) and Regex.match?(~r/\A[\x21-\x7e]{1,2048}\z/, href),
         %URI{scheme: "https", host: host, userinfo: nil, port: port}
         when is_binary(host) and host != "" <- parsed(href) do
      host = String.downcase(host)
      if port in [nil, 443], do: "https://" <> host, else: "https://#{host}:#{port}"
    else
      _other -> nil
    end
  end

  def origin(_other), do: nil

  defp parsed(href) do
    case URI.new(href) do
      {:ok, uri} -> uri
      {:error, _part} -> nil
    end
  end

  defp allowed?(%{"href" => href}, origins) do
    case origin(href) do
      nil -> false
      origin -> origin in origins
    end
  end

  defp fit(content, prepared) do
    parts = Enum.map(prepared, &elem(&1, 0))

    referenced =
      for {{_part, raw}, at} when raw != nil <- Enum.with_index(prepared),
          into: %{},
          do: {Integer.to_string(at), %{"raw" => raw}}

    shrink(content, parts, referenced)
  end

  defp shrink(content, parts, referenced) do
    payload = Jason.encode!(Map.put(content, "parts", parts))

    cond do
      byte_size(payload) <= @max_bytes -> fitted(content, payload, referenced)
      largest(parts) == nil -> {:error, {:too_large, over("max_bytes", @max_bytes, payload)}}
      true -> moved(content, parts, referenced, largest(parts))
    end
  end

  defp moved(content, parts, referenced, at) do
    part = Enum.at(parts, at)
    key = Integer.to_string(at)
    entry = referenced |> Map.get(key, %{}) |> Map.put("text", part["text"])
    parts = List.replace_at(parts, at, Map.put(part, "text", nil))
    shrink(content, parts, Map.put(referenced, key, entry))
  end

  defp largest(parts) do
    inline =
      for {%{"kind" => "text", "text" => text}, at} when is_binary(text) <-
            Enum.with_index(parts),
          do: {byte_size(text), at}

    case inline do
      [] -> nil
      sized -> sized |> Enum.max() |> elem(1)
    end
  end

  defp fitted(content, payload, referenced) when referenced == %{},
    do: {:ok, prepared(content, payload, nil)}

  defp fitted(content, payload, referenced) do
    encoded = Jason.encode!(%{"v" => 1, "parts" => referenced})

    if byte_size(encoded) <= @referenced_max_bytes,
      do: {:ok, prepared(content, payload, encoded)},
      else: {:error, {:too_large, over("referenced_max_bytes", @referenced_max_bytes, encoded)}}
  end

  defp prepared(content, payload, referenced) do
    %{
      payload: payload,
      referenced: referenced,
      digest: :crypto.hash(:sha256, payload),
      links_withheld: content["links_withheld"]
    }
  end

  defp over(name, limit, encoded),
    do: %{limit_name: "mailbox.message." <> name, limit: limit, actual: byte_size(encoded)}

  # C-76
  # INV-30
  # AG-38
  # AG-39
  # AG-40
  # AG-68
  @doc """
  The typed data of a message record. `record` is the row of the record, `stored` the decoded payload `prepare/2` wrote (or `nil` when the record holds none) and `referenced` its decoded referenced content, or `nil`. With `:inline` a text or a raw form that is kept as referenced content appears as a reference only; with `:referenced` it is given in full, between the same marks. Every part draws a fresh mark value from `nonce`.
  """
  @spec message_data(map(), map() | nil, map() | nil, include(), (-> UntrustedContent.nonce())) ::
          Jason.OrderedObject.t()
  def message_data(record, stored, referenced, include, nonce \\ &UntrustedContent.nonce/0)
      when include in [:inline, :referenced] and is_function(nonce, 0) do
    stored = stored || %{}
    label = record["trust_label"] || "unauthenticated"
    source = source(stored, label)

    parts =
      stored
      |> Map.get("parts", [])
      |> Enum.with_index()
      |> Enum.map(fn {part, at} ->
        kept = get_in(referenced || %{}, ["parts", Integer.to_string(at)]) || %{}
        part(part, at, kept, %{record: record, source: source, include: include}, nonce.())
      end)

    data(record, %{
      "message_type" => "message",
      "trust_label" => label,
      "sender" => sender_view(stored["sender"], label),
      "channel" => stored["channel"],
      "subject_digest" => stored["subject_digest"],
      "parts" => parts,
      "links" => Map.get(stored, "links", []),
      "links_withheld" => Map.get(stored, "links_withheld", 0)
    })
  end

  defp source(stored, label) do
    %{
      "author" => stored["sender"],
      "verified" => label == "authenticated",
      "channel" => stored["channel"]
    }
  end

  defp sender_view(nil, _label), do: nil
  defp sender_view(sender, label), do: Map.put(sender, "verified", label == "authenticated")

  defp part(%{"kind" => "text"} = part, at, kept, context, nonce) do
    text = part["text"] || if(context.include == :referenced, do: kept["text"])
    raw = if context.include == :referenced, do: kept["raw"]

    Jason.OrderedObject.new([
      {"kind", "text"},
      {"mediaType", part["media_type"]},
      {"audience", part["audience"]},
      {"text", marked(text, nonce)},
      {"untrusted", untrusted(nonce, context.source)},
      {"content_ref", reference(part["text"] == nil, context.record, at, part["text_bytes"])},
      {"raw_ref", reference(part["raw_bytes"] != nil, context.record, at, part["raw_bytes"])},
      {"raw_mediaType", part["raw_media_type"]},
      {"raw_text", marked(raw, nonce)}
    ])
  end

  defp part(%{"kind" => "data"} = part, _at, _kept, context, nonce) do
    Jason.OrderedObject.new([
      {"kind", "data"},
      {"mediaType", part["media_type"]},
      {"audience", part["audience"]},
      {"data", escaped(part["data"])},
      {"untrusted", untrusted(nonce, context.source)}
    ])
  end

  defp marked(nil, _nonce), do: nil
  defp marked(text, nonce), do: UntrustedContent.mark(text, nonce)

  defp untrusted(nonce, source), do: %{"nonce" => nonce, "source" => source}

  defp reference(false, _record, _at, _bytes), do: nil

  defp reference(true, record, at, bytes) do
    %{
      "record_id" => Relay.ExternalId.encode("mbr", record["id"]),
      "part" => at,
      "bytes" => bytes
    }
  end

  defp escaped(text) when is_binary(text), do: UntrustedContent.escape(text)
  defp escaped(list) when is_list(list), do: Enum.map(list, &escaped/1)

  defp escaped(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {escaped(key), escaped(value)} end)

  defp escaped(other), do: other

  # C-76
  # AG-25
  # AG-26
  # AG-30
  # AG-39
  @doc "The typed data of a waitpoint event record: the result the event names, the waitpoint and, for the event of a resolution, who answered, on which channel, at which evidence level and the digests of the subject and of the response. `waitpoint` is the waitpoint as `Relay.Agents.Waitpoint.read/2` returns it, or `nil`. The message has no parts: Relay writes no text of its own to an agent."
  @spec waitpoint_data(map(), map() | nil) :: Jason.OrderedObject.t()
  def waitpoint_data(record, waitpoint) do
    response = resolved(record["event_type"], waitpoint)

    data(record, %{
      "message_type" => "waitpoint_event",
      "result" => result(record["event_type"]),
      "responder" => responder(response),
      "channel" => response && channel_name(response.via),
      "evidence_level" => response && response.evidence_level,
      "subject_digest" => digest_text(subject(response, waitpoint)),
      "response_digest" => response && digest_text(response.value_digest)
    })
  end

  defp resolved("waitpoint.resolved", %{response: %{} = response}), do: response
  defp resolved(_event_type, _waitpoint), do: nil

  defp result("waitpoint." <> result) do
    if Regex.match?(@result, result), do: result
  end

  defp result(_other), do: nil

  defp responder(nil), do: nil

  defp responder(response) do
    prefix = if response.responder_kind == "agent", do: "agt", else: "sub"

    %{
      "recipient_id" => Relay.ExternalId.encode(prefix, response.responder_recipient_id),
      "kind" => response.responder_kind
    }
  end

  defp channel_name(via) when is_binary(via) do
    if Regex.match?(@channel, via), do: via
  end

  defp channel_name(_other), do: nil

  defp subject(%{subject_digest: digest}, _waitpoint), do: digest
  defp subject(nil, %{subject_digest: digest}), do: digest
  defp subject(nil, _waitpoint), do: nil

  defp digest_text(<<_::256>> = digest), do: "sha256:" <> Base.encode16(digest, case: :lower)
  defp digest_text(_other), do: nil

  defp data(record, fields) do
    Jason.OrderedObject.new([
      {"message_type", fields["message_type"]},
      {"mailbox_id", Relay.ExternalId.encode("mbx", record["mailbox_id"])},
      {"epoch", record["epoch"]},
      {"seq", record["seq"]},
      {"trust_label", fields["trust_label"]},
      {"sender", fields["sender"]},
      {"channel", fields["channel"]},
      {"waitpoint_id", waitpoint_id(record["waitpoint_id"])},
      {"result", fields["result"]},
      {"responder", fields["responder"]},
      {"evidence_level", fields["evidence_level"]},
      {"subject_digest", fields["subject_digest"]},
      {"response_digest", fields["response_digest"]},
      {"content_encryption", nil},
      {"parts", Map.get(fields, "parts", [])},
      {"links", Map.get(fields, "links", [])},
      {"links_withheld", Map.get(fields, "links_withheld", 0)}
    ])
  end

  defp waitpoint_id(nil), do: nil
  defp waitpoint_id(id), do: Relay.ExternalId.encode("wp", id)

  # C-76
  # AG-40
  @doc "The CloudEvents 1.0 envelope of a record around its typed data, as the bytes that are signed and delivered: `id` is the record's durable handle, `type` its event type, `subject` its mailbox and `time` when it was appended."
  @spec envelope(map(), Jason.OrderedObject.t()) :: binary()
  def envelope(record, %Jason.OrderedObject{} = data) do
    Jason.encode!(
      Jason.OrderedObject.new([
        {"specversion", "1.0"},
        {"id", Relay.ExternalId.encode("mbr", record["id"])},
        {"source", "/v1/mailbox"},
        {"type", record["event_type"]},
        {"subject", Relay.ExternalId.encode("mbx", record["mailbox_id"])},
        {"time", DateTime.to_iso8601(record["created_at"])},
        {"datacontenttype", "application/json"},
        {"data", data}
      ])
    )
  end
end
