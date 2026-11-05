defmodule Relay.Channels.Sms do
  @moduledoc """
  The SMS rules of a send that depend on the provider, as pure functions of the provider's declaration (`Relay.ChannelDeclarations`), the destination and the rendered text.

    * Encoding (CH-48, CH-75, TP-18). Every send names its encoding, `GSM7`, `GSM7_TR` or `UCS2`; nothing is left to the provider's detection. The provider catalogue (`sms` in the declaration) lists the encodings the adapter can name and the provider's `turkish_single_shift`, `verified` or `unverified`: on an unverified provider `GSM7_TR` is never used, so Turkish text goes as `UCS2`. Every provider starts unverified; `verified` needs the device evidence in `turkish_single_shift_evidence` and is set only by a new data set version (CH-75). The segment count reserves the provider × country `segment_reserve` row, the operator prefix of a TR SMS with a sender header, 0 when the provider declares none.
    * TR route (CH-51). A `+90` destination is sent only through a provider whose catalogue says `btk_authorized`; any other route stops with `channel.tr_route_unauthorized`, and with `channel.foreign_route_url` when the text carries a link, which the operators never deliver.
    * Product (CH-53). The `security` class goes to the provider's OTP product when the catalogue declares one (`otp_product`), and never through an account of the standard lane (`traffic/2`); the other classes never through the security lane.
  """

  alias Relay.Channels.SmsSender

  @encodings ~w(GSM7 GSM7_TR UCS2)
  @url ~r{(?:\bhttps?://|\bwww\.)[^\s]+|\b[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)*\.(?:com|net|org|info|biz|io|co|me|ly|gl|link|app|shop|site|online|tr)(?:/[^\s]*)?\b}iu

  @type measure :: %{
          encoding: String.t(),
          segments: non_neg_integer(),
          units: non_neg_integer(),
          reserved: non_neg_integer()
        }

  @doc "The SMS catalogue of a provider declaration, or `nil` when it has none."
  @spec catalog(map()) :: map() | nil
  def catalog(%{"sms" => %{} = sms}), do: sms
  def catalog(_declaration), do: nil

  @doc "The encoding names a send may carry."
  @spec encodings() :: [String.t(), ...]
  def encodings, do: @encodings

  # CH-48
  # CH-75
  @doc "Returns true when the provider's Turkish single shift support is verified with device evidence."
  @spec turkish_shift_verified?(map()) :: boolean()
  def turkish_shift_verified?(declaration) do
    case catalog(declaration) do
      %{"turkish_single_shift" => "verified", "turkish_single_shift_evidence" => evidence}
      when is_binary(evidence) and evidence != "" ->
        true

      _unverified ->
        false
    end
  end

  # CH-48
  # CH-75
  @doc "The units the provider reserves in a country's SMS before the text (`segment_reserve`), 0 when it declares none."
  @spec reserved(map(), String.t() | nil) :: non_neg_integer()
  def reserved(declaration, country) do
    rows =
      case catalog(declaration) do
        %{"segment_reserve" => rows} when is_list(rows) -> rows
        _none -> []
      end

    case Enum.find(rows, &(&1["country"] == country)) do
      %{"septets" => septets} when is_integer(septets) and septets >= 0 -> septets
      _none -> 0
    end
  end

  # CH-48
  # CH-75
  # TP-18
  @doc "The explicit encoding of a send and its segment count on a provider, for a destination country; `{:error, \"channel.sms_encoding_unsupported\"}` when the provider can name no encoding that carries the text."
  @spec encoding(map(), String.t(), String.t() | nil) :: {:ok, measure()} | {:error, String.t()}
  def encoding(declaration, text, country) when is_binary(text) do
    reserved = reserved(declaration, country)

    case Relay.Templates.sms_measure(text, allowed(declaration), reserved) do
      {:ok, measure} -> {:ok, Map.put(measure, :reserved, reserved)}
      :error -> {:error, "channel.sms_encoding_unsupported"}
    end
  end

  defp allowed(declaration) do
    named =
      case catalog(declaration) do
        %{"encodings" => names} when is_list(names) -> Enum.filter(names, &(&1 in @encodings))
        _none -> []
      end

    if turkish_shift_verified?(declaration), do: named, else: named -- ["GSM7_TR"]
  end

  # CH-51
  @doc "Returns true when a phone number in E.164 form is in Türkiye (`+90`)."
  @spec turkish_number?(String.t()) :: boolean()
  def turkish_number?("+90" <> _rest), do: true
  def turkish_number?(_number), do: false

  # CH-51
  @doc "Returns true when the provider is a BTK-authorized operator or aggregator."
  @spec btk_authorized?(map()) :: boolean()
  def btk_authorized?(declaration), do: match?(%{"btk_authorized" => true}, catalog(declaration))

  # CH-51
  @doc "Returns true when the text carries a link: a URL, a `www.` address or a bare domain name."
  @spec link?(String.t()) :: boolean()
  def link?(text) when is_binary(text), do: Regex.match?(@url, text)

  # CH-51
  @doc "Checks the TR route of a send: a `+90` destination needs a BTK-authorized provider; the rule of a refused route, the link rule first."
  @spec route(map(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def route(declaration, number, text) do
    cond do
      not turkish_number?(number) -> :ok
      btk_authorized?(declaration) -> :ok
      link?(text) -> {:error, "channel.foreign_route_url"}
      true -> {:error, "channel.tr_route_unauthorized"}
    end
  end

  # CH-48
  @doc "The country of an E.164 number whose segment reserve a provider may declare: `TR` for `+90`, `nil` for every other number."
  @spec country(String.t()) :: String.t() | nil
  def country(number), do: if(turkish_number?(number), do: "TR")

  # CH-48
  # CH-50
  # CH-51
  # CH-53
  @doc "The checks of an SMS send on a provider, in order: the sender identity's rules for the class, the TR route and the explicit encoding; the request fields (`sender`, `encoding`, `product`) or `{:skip, rule_id}`."
  @spec preflight(map(), map(), String.t() | nil, String.t(), map() | binary()) ::
          {:ok, map()} | {:skip, String.t()}
  def preflight(declaration, sender, message_class, number, content) do
    text = text(content)
    identity = SmsSender.identity(sender)

    with :ok <- SmsSender.check(identity, message_class),
         :ok <- route(declaration, number, text),
         {:ok, measure} <- encoding(declaration, text, country(number)) do
      product = product(declaration, message_class)
      {:ok, %{sender: sender, encoding: measure.encoding, product: product}}
    else
      {:error, rule_id} -> {:skip, rule_id}
    end
  end

  defp text(%{"body" => body}) when is_binary(body), do: body
  defp text(body) when is_binary(body), do: body
  defp text(_content), do: ""

  # CH-53
  @doc "The provider product a class is sent with: `\"otp\"` for `security` when the provider declares an OTP product, `\"standard\"` otherwise."
  @spec product(map(), String.t() | nil) :: String.t()
  def product(declaration, "security") do
    if match?(%{"otp_product" => true}, catalog(declaration)), do: "otp", else: "standard"
  end

  def product(_declaration, _class), do: "standard"

  # CH-53
  @doc "The provider account traffic a class may use: `\"security\"` for the `security` class, `\"standard\"` for every other class; an OTP never shares an account or a credit pool with a campaign."
  @spec traffic(String.t() | nil) :: String.t()
  def traffic("security"), do: "security"
  def traffic(_class), do: "standard"

  # CH-53
  @doc "Keeps the provider accounts of the class's traffic."
  @spec traffic([map()], String.t() | nil) :: [map()]
  def traffic(accounts, class) when is_list(accounts) do
    wanted = traffic(class)
    Enum.filter(accounts, &(Map.get(&1, "traffic", "standard") == wanted))
  end
end
