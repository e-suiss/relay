defmodule Relay.Channels.Email.Arf do
  @moduledoc """
  Abuse reporting format feedback reports (RFC 5965) inside a `multipart/report` (RFC 6522): the `message/feedback-report` part is read into its fields and the original message's header fields are kept, so the caller finds the VERP return path, `Feedback-ID` and `Message-ID` of the reported message. Authentication failure reports (RFC 6591, `Feedback-Type: auth-failure`) are read the same way.

  A report is `conformant` when it carries the three required fields `Feedback-Type`, `User-Agent` and `Version`; a report without `Feedback-Type` is refused. Addresses come back wrapped in `Relay.Redacted`.
  """

  alias Relay.Channels.Email.Dsn
  alias Relay.Channels.Email.Mime
  alias Relay.Redacted

  @types ["message/feedback-report"]

  @type t :: %{
          feedback_type: String.t(),
          conformant: boolean(),
          user_agent: String.t() | nil,
          version: String.t() | nil,
          original_mail_from: Redacted.t() | nil,
          original_rcpt_to: [Redacted.t()],
          arrival_date: String.t() | nil,
          reporting_mta: String.t() | nil,
          source_ip: String.t() | nil,
          incidents: pos_integer(),
          reported_domains: [String.t()],
          original_headers: [Mime.header()]
        }

  # CH-39
  # CH-77
  @doc "Reads a feedback report; `:not_a_report` when the message has no feedback report part and `:invalid_report` when it has no `Feedback-Type`."
  @spec parse(binary()) :: {:ok, t()} | {:error, :not_a_report | :invalid_report}
  def parse(message) when is_binary(message) do
    leaves = message |> Mime.parse() |> Mime.leaves()

    case Enum.find(leaves, fn {type, _part} -> type in @types end) do
      {_type, part} -> part |> Mime.decoded() |> Mime.crlf() |> report(leaves)
      nil -> {:error, :not_a_report}
    end
  end

  defp report(body, leaves) do
    fields = body |> String.trim_leading() |> Mime.split() |> elem(0) |> Mime.fields()

    case Mime.header(fields, "feedback-type") do
      nil ->
        {:error, :invalid_report}

      type ->
        user_agent = Mime.header(fields, "user-agent")
        version = Mime.header(fields, "version")

        {:ok,
         %{
           feedback_type: type |> String.trim() |> String.downcase(:ascii),
           conformant: user_agent != nil and version != nil,
           user_agent: user_agent,
           version: version,
           original_mail_from: fields |> Mime.header("original-mail-from") |> address(),
           original_rcpt_to:
             fields |> Mime.headers("original-rcpt-to") |> Enum.map(&address/1) |> compact(),
           arrival_date: Mime.header(fields, "arrival-date"),
           reporting_mta: Mime.header(fields, "reporting-mta"),
           source_ip: Mime.header(fields, "source-ip"),
           incidents: fields |> Mime.header("incidents") |> incidents(),
           reported_domains: Mime.headers(fields, "reported-domain"),
           original_headers: Dsn.original_headers(leaves)
         }}
    end
  end

  defp address(nil), do: nil

  defp address(value) do
    case value |> String.trim() |> String.trim_leading("<") |> String.trim_trailing(">") do
      "" -> nil
      address -> Redacted.wrap(address)
    end
  end

  defp compact(values), do: Enum.reject(values, &is_nil/1)

  defp incidents(nil), do: 1

  defp incidents(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _other -> 1
    end
  end
end
