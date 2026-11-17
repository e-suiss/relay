defmodule Relay.Compliance.SmsKeyword do
  @moduledoc """
  The keywords of an inbound SMS (PC-37), independent of the provider and in several languages. A message is a keyword only when the whole message is one:

  | Set | Keywords | Effect |
  |---|---|---|
  | `:tr_refusal` | `RET`, `IPTAL`, `İPTAL`, `DUR`, `H` | a refusal notice for the brand's marketing on SMS |
  | `:stop` | `STOP`, `QUIT`, `END`, `REVOKE`, `OPT OUT`, `CANCEL`, `UNSUBSCRIBE` | a refusal notice whose scope the sender's country gives (PC-61) |
  | `:help` | `HELP`, `YARDIM` | an information reply |
  | `:restart` | `START`, `UNSTOP` | a new evidenced consent in Relay's own copy |

  Matching folds the letters the Turkish way (`İ`, `I`, `ı` and `i` are one letter), ignores case, leading and trailing white space and the width of the space inside `OPT OUT`, and ignores full stops and exclamation marks at the end of the message (`STOP.`, `Stop!`); any other character makes the message something else than a keyword. A message longer than 64 bytes is never a keyword.

  The scope of a refusal keyword is data (PC-39, PC-61): a `:stop` keyword from a number whose country has a revocation scope for SMS in the compliance table takes that scope and its channels; every other refusal keyword is `all_marketing` on SMS. The replies are fixed texts without marketing content, in Turkish for a Turkish locale and in English otherwise, written in the GSM 7 bit default alphabet so that a reply is one segment on every provider.
  """

  @sets %{
    "ret" => {:tr_refusal, "RET"},
    "iptal" => {:tr_refusal, "IPTAL"},
    "dur" => {:tr_refusal, "DUR"},
    "h" => {:tr_refusal, "H"},
    "stop" => {:stop, "STOP"},
    "quit" => {:stop, "QUIT"},
    "end" => {:stop, "END"},
    "revoke" => {:stop, "REVOKE"},
    "opt out" => {:stop, "OPT OUT"},
    "cancel" => {:stop, "CANCEL"},
    "unsubscribe" => {:stop, "UNSUBSCRIBE"},
    "help" => {:help, "HELP"},
    "yardim" => {:help, "YARDIM"},
    "start" => {:restart, "START"},
    "unstop" => {:restart, "UNSTOP"}
  }
  @max_bytes 64
  @marketing %{scope: "all_marketing", channels: ["sms"]}

  @type set :: :tr_refusal | :stop | :help | :restart
  @type revocation :: %{scope: String.t(), channels: [String.t()]}
  @type reply :: :refused | :help | :restarted

  # PC-37
  @doc "The keyword set and the canonical keyword of a message, or `:none` when the message is not a keyword."
  @spec classify(term()) :: {set(), String.t()} | :none
  def classify(text) when is_binary(text) and byte_size(text) <= @max_bytes do
    if String.valid?(text), do: Map.get(@sets, fold(text), :none), else: :none
  end

  def classify(_text), do: :none

  # PC-37
  @doc "A message as it is compared with the keywords: Turkish letter folding, lower case, white space trimmed and narrowed, closing full stops and exclamation marks dropped."
  @spec fold(String.t()) :: String.t()
  def fold(text) when is_binary(text) do
    text
    |> String.replace(["İ", "I", "ı"], "i")
    |> String.downcase()
    |> String.replace("̇", "")
    |> String.split()
    |> Enum.join(" ")
    |> String.replace(~r/[ .!]+\z/, "")
  end

  # PC-37
  @doc "Whether a keyword set is a refusal."
  @spec refusal?(set()) :: boolean()
  def refusal?(set), do: set in [:tr_refusal, :stop]

  # PC-39
  # PC-61
  @doc "The scope of a refusal keyword and the channels it covers. `scopes` are the revocation scopes the compliance table gives for SMS in the countries the sender's number may be in, `nil` for a country without one."
  @spec revocation(set(), [revocation() | nil]) :: revocation()
  def revocation(:stop, scopes) when is_list(scopes) do
    case Enum.find(scopes, &is_map/1) do
      %{scope: scope, channels: [_ | _] = channels} when is_binary(scope) ->
        %{scope: scope, channels: Enum.uniq(["sms" | channels])}

      _none ->
        @marketing
    end
  end

  def revocation(_set, _scopes), do: @marketing

  # PC-37
  @doc "The text of a reply in the language of `locale`: the confirmation of a refusal, the information reply or the confirmation of a restart. `brand` is the brand's name or SMS header, or `nil`."
  @spec reply(reply(), String.t() | nil, String.t() | nil) :: String.t()
  def reply(kind, locale, brand), do: prefix(brand) <> text(kind, language(locale))

  defp language("tr" <> _rest), do: :tr
  defp language(_other), do: :en

  defp prefix(brand) when is_binary(brand) and brand != "", do: brand <> ": "
  defp prefix(_none), do: ""

  defp text(:refused, :tr),
    do: "Ret talebiniz alindi. Bu numaraya ticari SMS gonderilmeyecek."

  defp text(:refused, :en),
    do: "You are unsubscribed and will receive no more marketing messages."

  defp text(:help, :tr),
    do: "Ticari SMS almamak icin RET yazip bu numaraya gonderin."

  defp text(:help, :en),
    do: "Reply STOP to this number to receive no more marketing messages."

  defp text(:restarted, :tr),
    do: "Onayiniz kaydedildi. Cikmak icin RET yazip gonderin."

  defp text(:restarted, :en),
    do: "You are subscribed again. Reply STOP to unsubscribe."
end
