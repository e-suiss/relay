defmodule Relay.Channels.Email.Dsn do
  @moduledoc """
  Delivery status notifications (RFC 3464) inside a `multipart/report` (RFC 6522). The `message/delivery-status` part (or `message/global-delivery-status`, RFC 6533) is read into its per-message fields and one entry per recipient; the returned or referenced original header fields are kept so the caller can read the VERP return path, `Feedback-ID` and `Message-ID` of the bounced message.

  Addresses, diagnostics and the human-readable text are personal data and come back wrapped in `Relay.Redacted`. A message without a delivery status part is not a report here; it is classified `unknown` (CH-77).
  """

  alias Relay.Channels.Email.Mime
  alias Relay.Channels.Email.StatusCode
  alias Relay.Redacted

  @status_types ["message/delivery-status", "message/global-delivery-status"]
  @original_types ["message/rfc822", "message/global", "text/rfc822-headers"]
  @original_header_types ["message/global-headers"]

  @type recipient :: %{
          final_recipient: Redacted.t() | nil,
          original_recipient: Redacted.t() | nil,
          action: String.t() | nil,
          status: StatusCode.t() | nil,
          status_text: String.t() | nil,
          diagnostic_type: String.t() | nil,
          diagnostic: Redacted.t() | nil,
          remote_mta: String.t() | nil,
          will_retry_until: String.t() | nil
        }

  @type t :: %{
          report_type: String.t() | nil,
          reporting_mta: String.t() | nil,
          original_envelope_id: String.t() | nil,
          arrival_date: String.t() | nil,
          recipients: [recipient()],
          original_headers: [Mime.header()],
          human_text: Redacted.t() | nil
        }

  # CH-39
  # CH-77
  @doc "Reads a delivery status notification; `:not_a_report` when the message has no delivery status part."
  @spec parse(binary()) :: {:ok, t()} | {:error, :not_a_report}
  def parse(message) when is_binary(message) do
    root = Mime.parse(message)
    {_type, params} = Mime.content_type(root.headers)
    leaves = Mime.leaves(root)

    case Enum.find(leaves, fn {type, _part} -> type in @status_types end) do
      {_type, part} -> {:ok, report(params, part, leaves)}
      nil -> {:error, :not_a_report}
    end
  end

  defp report(params, part, leaves) do
    [message_fields | recipient_groups] = part |> Mime.decoded() |> groups()

    %{
      report_type: Map.get(params, "report-type"),
      reporting_mta: Mime.header(message_fields, "reporting-mta"),
      original_envelope_id: Mime.header(message_fields, "original-envelope-id"),
      arrival_date: Mime.header(message_fields, "arrival-date"),
      recipients: Enum.map(recipient_groups, &recipient/1),
      original_headers: original_headers(leaves),
      human_text: human_text(leaves)
    }
  end

  @doc "Splits the body of a delivery status part into its field groups: the per-message group first, then one per recipient. A body that starts with recipient fields gets an empty per-message group."
  @spec groups(binary()) :: [[Mime.header()], ...]
  def groups(body) do
    groups =
      body
      |> Mime.crlf()
      |> String.trim_leading()
      |> :binary.split("\r\n\r\n", [:global])
      |> Enum.map(&Mime.fields/1)
      |> Enum.reject(&(&1 == []))

    case groups do
      [] -> [[]]
      [first | _rest] = all -> if recipient_group?(first), do: [[] | all], else: all
    end
  end

  defp recipient_group?(fields),
    do: Mime.header(fields, "final-recipient") != nil or Mime.header(fields, "action") != nil

  defp recipient(fields) do
    status_text = Mime.header(fields, "status")
    {diagnostic_type, diagnostic} = typed(Mime.header(fields, "diagnostic-code"))

    %{
      final_recipient: fields |> Mime.header("final-recipient") |> address(),
      original_recipient: fields |> Mime.header("original-recipient") |> address(),
      action: fields |> Mime.header("action") |> lower(),
      status: status(status_text),
      status_text: status_text,
      diagnostic_type: diagnostic_type,
      diagnostic: wrap(diagnostic),
      remote_mta: Mime.header(fields, "remote-mta"),
      will_retry_until: Mime.header(fields, "will-retry-until")
    }
  end

  defp status(nil), do: nil

  defp status(text) do
    first = text |> String.split([" ", "(", "\t"], parts: 2) |> hd()

    case StatusCode.parse(first) do
      {:ok, code} -> code
      :error -> nil
    end
  end

  @doc "Splits a typed DSN field such as `rfc822; user@example.com` or `smtp; 550 ...` into its lowercased type and its value."
  @spec typed(String.t() | nil) :: {String.t() | nil, String.t() | nil}
  def typed(nil), do: {nil, nil}

  def typed(value) do
    case :binary.split(value, ";") do
      [type, rest] -> {type |> String.trim() |> String.downcase(:ascii), String.trim(rest)}
      [_untyped] -> {nil, String.trim(value)}
    end
  end

  defp address(value) do
    case typed(value) do
      {_type, nil} -> nil
      {_type, text} -> text |> String.trim_leading("<") |> String.trim_trailing(">") |> wrap()
    end
  end

  defp lower(nil), do: nil
  defp lower(value), do: value |> String.trim() |> String.downcase(:ascii)

  defp wrap(nil), do: nil
  defp wrap(""), do: nil
  defp wrap(value), do: Redacted.wrap(value)

  @doc "The header fields of the original message carried in a report's leaves; empty when the report carries none."
  @spec original_headers([{String.t(), Mime.part()}]) :: [Mime.header()]
  def original_headers(leaves) do
    case Enum.find(leaves, fn {type, _part} -> type in @original_types end) do
      {_type, part} ->
        part |> Mime.decoded() |> Mime.parse() |> Map.fetch!(:headers)

      nil ->
        case Enum.find(leaves, fn {type, _part} -> type in @original_header_types end) do
          {_type, part} -> part |> Mime.decoded() |> Mime.crlf() |> Mime.fields()
          nil -> []
        end
    end
  end

  defp human_text(leaves) do
    case Enum.find(leaves, fn {type, _part} -> type == "text/plain" end) do
      {_type, part} -> wrap(Mime.decoded(part))
      nil -> nil
    end
  end
end
