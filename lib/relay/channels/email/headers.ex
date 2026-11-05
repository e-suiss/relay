defmodule Relay.Channels.Email.Headers do
  @moduledoc """
  The header fields Relay adds to every outgoing e-mail (CH-38):

  * every e-mail carries the VERP return path (the SMTP envelope sender, `Relay.Channels.Email.Verp`) and `Feedback-ID: <campaign>:<category>:<tenant>:<sender>`;
  * a marketing or bulk e-mail (`marketing`, `social`) also carries `List-Unsubscribe` with an HTTPS and a `mailto:` URI and `List-Unsubscribe-Post: List-Unsubscribe=One-Click` (RFC 8058); a transactional e-mail never does.

  Every field added here is named in `dkim_headers` and must be inside the DKIM `h=` list (`Relay.Channels.Email.Dkim`).
  """

  alias Relay.Channels.Email.Streams
  alias Relay.Error

  @feedback_part ~r/\A[A-Za-z0-9._\-]{1,64}\z/
  @uri_forbidden ~r/[\s<>,"]/

  @type input :: %{
          required(:class) => String.t(),
          required(:return_path) => String.t(),
          required(:feedback_id) => %{
            campaign: String.t(),
            category: String.t(),
            tenant: String.t(),
            sender: String.t()
          },
          optional(:unsubscribe) => %{https: String.t(), mailto: String.t()} | nil
        }

  @type t :: %{
          return_path: String.t(),
          headers: [{String.t(), String.t()}],
          dkim_headers: [String.t()]
        }

  # CH-38
  # PC-35
  @doc "The header fields of an e-mail of `class`. A bulk e-mail without both unsubscribe URIs is refused, and so is a transactional one that carries them."
  @spec build(input()) :: {:ok, t()} | {:error, Error.t()}
  def build(%{class: class, return_path: return_path, feedback_id: feedback} = input) do
    with {:ok, stream} <- Streams.stream(class),
         :ok <- return_path(return_path),
         {:ok, feedback_id} <- feedback_id(feedback),
         {:ok, unsubscribe} <- unsubscribe(stream, Map.get(input, :unsubscribe)) do
      headers = [{"Feedback-ID", feedback_id} | unsubscribe]

      {:ok,
       %{
         return_path: return_path,
         headers: headers,
         dkim_headers: Enum.map(headers, fn {name, _value} -> String.downcase(name) end)
       }}
    end
  end

  # CH-38
  @doc "The `Feedback-ID` value; each of the four parts is 1 to 64 characters of `A-Z a-z 0-9 . _ -`."
  @spec feedback_id(map()) :: {:ok, String.t()} | {:error, Error.t()}
  def feedback_id(%{campaign: campaign, category: category, tenant: tenant, sender: sender}) do
    parts = [campaign, category, tenant, sender]

    if Enum.all?(parts, &(is_binary(&1) and Regex.match?(@feedback_part, &1))),
      do: {:ok, Enum.join(parts, ":")},
      else: invalid("a Feedback-ID part is 1 to 64 characters of A-Z a-z 0-9 . _ -")
  end

  defp return_path(address) when is_binary(address) do
    case String.split(address, "@") do
      [local, domain] when local != "" and domain != "" ->
        if Regex.match?(@uri_forbidden, address),
          do: invalid("the return path is not an address"),
          else: :ok

      _other ->
        invalid("the return path is not an address")
    end
  end

  defp return_path(_address), do: invalid("the return path is not an address")

  defp unsubscribe("marketing", %{https: "https://" <> _ = https, mailto: "mailto:" <> _ = to}) do
    if Regex.match?(@uri_forbidden, https) or Regex.match?(@uri_forbidden, to) do
      invalid("an unsubscribe URI carries a character it cannot")
    else
      {:ok,
       [
         {"List-Unsubscribe", "<" <> https <> ">, <" <> to <> ">"},
         {"List-Unsubscribe-Post", "List-Unsubscribe=One-Click"}
       ]}
    end
  end

  defp unsubscribe("marketing", _unsubscribe),
    do: invalid("a bulk e-mail carries an HTTPS and a mailto unsubscribe URI")

  defp unsubscribe("transactional", nil), do: {:ok, []}

  defp unsubscribe("transactional", _unsubscribe),
    do: invalid("a transactional e-mail carries no List-Unsubscribe")

  defp invalid(message), do: {:error, Error.new(:invalid_email_headers, message)}
end
