defmodule Relay.Iys.Consent do
  @moduledoc """
  One consent movement as İYS takes it, and the checks Relay runs before it sends one (PC-34, PC-27, §13.5.3). It is pure.

  A movement is a map with `:recipient` (the address in clear), `:type` (`MESAJ`, `ARAMA` or `EPOSTA`), `:status` (`ONAY` or `RET`), `:recipient_type` (`BIREYSEL` or `TACIR`), `:source` (one of the sources a service provider may write) and `:consent_at` (the instant the consent or the refusal was given).

  İYS counts refused requests against the caller, so a request İYS would refuse is never sent: `validate/2` checks the phone format (E.164, at most 15 characters, never `+900…`), the e-mail format (6 to 265 characters, lower case, no space), the date range (not in the future, not before 1 May 2015, and exactly that day for `HS_2015`), the fixed value sets and that `HS_KARAR` is a refusal; `validate_batch/3` adds the size of a list and that no recipient appears twice in it.

  The Relay channel maps to the İYS type (`sms` to `MESAJ`, `voice` to `ARAMA`, `email` to `EPOSTA`); every other channel is outside İYS. The source of a Relay or Access consent maps to the İYS source set with `source/1`; a source without a mapping is not guessed.
  """

  alias Relay.Iys.Calendar

  @types %{"sms" => "MESAJ", "voice" => "ARAMA", "email" => "EPOSTA"}
  @channels %{"MESAJ" => "sms", "ARAMA" => "voice", "EPOSTA" => "email"}
  @statuses ~w(ONAY RET)
  @recipient_types %{"individual" => "BIREYSEL", "merchant" => "TACIR"}
  @writable ~w(HS_FIZIKSEL_ORTAM HS_ISLAK_IMZA HS_WEB HS_CAGRI_MERKEZI HS_SOSYAL_MEDYA
               HS_EPOSTA HS_MESAJ HS_MOBIL HS_EORTAM HS_ETKINLIK HS_2015 HS_ATM HS_KARAR)
  @sources %{
    "web" => "HS_WEB",
    "preference_center" => "HS_WEB",
    "hosted_page" => "HS_WEB",
    "mobile" => "HS_MOBIL",
    "mobile_app" => "HS_MOBIL",
    "app" => "HS_MOBIL",
    "sms" => "HS_MESAJ",
    "sms_keyword" => "HS_MESAJ",
    "email" => "HS_EPOSTA",
    "one_click" => "HS_EPOSTA",
    "unsubscribe_page" => "HS_EPOSTA",
    "complaint" => "HS_EPOSTA",
    "call_center" => "HS_CAGRI_MERKEZI",
    "ivr" => "HS_CAGRI_MERKEZI",
    "social_media" => "HS_SOSYAL_MEDYA",
    "physical" => "HS_FIZIKSEL_ORTAM",
    "store" => "HS_FIZIKSEL_ORTAM",
    "wet_signature" => "HS_ISLAK_IMZA",
    "form" => "HS_ISLAK_IMZA",
    "event" => "HS_ETKINLIK",
    "atm" => "HS_ATM",
    "electronic" => "HS_EORTAM",
    "legacy_2015" => "HS_2015",
    "tenant_decision" => "HS_KARAR",
    "operator" => "HS_KARAR"
  }
  @phone ~r/\A\+[1-9][0-9]{6,13}\z/
  @email ~r/\A[a-z0-9][a-z0-9._%+-]*@[a-z0-9][a-z0-9.-]*\.[a-z]{2,}\z/
  @earliest ~U[2015-04-30 21:00:00Z]

  @type t :: %{
          recipient: String.t(),
          type: String.t(),
          status: String.t(),
          recipient_type: String.t(),
          source: String.t(),
          consent_at: DateTime.t()
        }
  @type refusal ::
          :invalid_type
          | :invalid_status
          | :invalid_recipient_type
          | :invalid_source
          | :source_requires_rejection
          | :invalid_phone
          | :invalid_email
          | :date_in_future
          | :date_too_early
          | :too_many
          | :repeated_recipient
          | :empty

  # PC-27
  @doc "The İYS consent type of a Relay channel, or `:out_of_scope` for a channel İYS does not know."
  @spec type(String.t()) :: {:ok, String.t()} | :out_of_scope
  def type(channel) do
    case Map.fetch(@types, channel) do
      {:ok, type} -> {:ok, type}
      :error -> :out_of_scope
    end
  end

  @doc "The Relay channel of an İYS consent type, or `nil`."
  @spec channel(String.t()) :: String.t() | nil
  def channel(type), do: Map.get(@channels, type)

  @doc "The İYS recipient type of a Relay recipient type; an absent one is an individual."
  @spec recipient_type(String.t() | nil) :: String.t()
  def recipient_type(type), do: Map.get(@recipient_types, type, "BIREYSEL")

  # PC-34
  @doc "The İYS source of a Relay or Access consent source: the mapped value, the value itself when it already is an İYS source a provider may write, or `:error`."
  @spec source(String.t() | nil) :: {:ok, String.t()} | :error
  def source(source) when is_binary(source) do
    upper = String.upcase(source)

    cond do
      is_map_key(@sources, source) -> {:ok, Map.fetch!(@sources, source)}
      upper in @writable -> {:ok, upper}
      true -> :error
    end
  end

  def source(_other), do: :error

  @doc "The address as İYS stores it: an e-mail address in lower case, a phone number as it is."
  @spec recipient(String.t(), String.t()) :: String.t()
  def recipient("EPOSTA", address), do: address |> String.trim() |> String.downcase()
  def recipient(_type, address), do: String.trim(address)

  # PC-34
  @doc "Checks one movement against the rules İYS refuses a request for; `now` is the current instant."
  @spec validate(t(), DateTime.t()) :: :ok | {:error, refusal()}
  def validate(%{} = consent, %DateTime{} = now) do
    with :ok <- member(consent.type, Map.keys(@channels), :invalid_type),
         :ok <- member(consent.status, @statuses, :invalid_status),
         :ok <- member(consent.recipient_type, ["BIREYSEL", "TACIR"], :invalid_recipient_type),
         :ok <- member(consent.source, @writable, :invalid_source),
         :ok <- decision(consent),
         :ok <- address(consent.type, consent.recipient) do
      date(consent, now)
    end
  end

  defp member(value, values, refusal), do: if(value in values, do: :ok, else: {:error, refusal})

  defp decision(%{source: "HS_KARAR", status: "ONAY"}), do: {:error, :source_requires_rejection}
  defp decision(_consent), do: :ok

  defp address("EPOSTA", address) do
    size = String.length(address)

    if size >= 6 and size <= 265 and Regex.match?(@email, address),
      do: :ok,
      else: {:error, :invalid_email}
  end

  defp address(_phone_type, "+900" <> _rest), do: {:error, :invalid_phone}

  defp address(_phone_type, address) do
    if Regex.match?(@phone, address), do: :ok, else: {:error, :invalid_phone}
  end

  defp date(%{source: "HS_2015", consent_at: at}, _now) do
    if DateTime.compare(at, @earliest) == :eq, do: :ok, else: {:error, :date_too_early}
  end

  defp date(%{consent_at: at}, now) do
    cond do
      DateTime.compare(at, now) == :gt -> {:error, :date_in_future}
      DateTime.compare(at, @earliest) == :lt -> {:error, :date_too_early}
      true -> :ok
    end
  end

  # PC-34
  @doc "Checks a list for the asynchronous add: at least one and at most `max` movements, each valid, and no recipient, type and recipient type twice. The first broken rule is returned with the index of its movement."
  @spec validate_batch([t()], DateTime.t(), pos_integer()) ::
          :ok | {:error, refusal(), non_neg_integer() | nil}
  def validate_batch([], _now, _max), do: {:error, :empty, nil}

  def validate_batch(consents, _now, max) when length(consents) > max,
    do: {:error, :too_many, nil}

  def validate_batch(consents, %DateTime{} = now, _max) do
    consents
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {consent, index}, {:ok, seen} ->
      key = {consent.recipient, consent.type, consent.recipient_type}

      case validate(consent, now) do
        :ok when is_map_key(seen, key) -> {:halt, {:error, :repeated_recipient, index}}
        :ok -> {:cont, {:ok, Map.put(seen, key, true)}}
        {:error, refusal} -> {:halt, {:error, refusal, index}}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      error -> error
    end
  end

  @doc "The request body of a movement: only the fields that have a value, the date in Turkey time."
  @spec body(t()) :: %{String.t() => String.t()}
  def body(%{} = consent) do
    %{
      "recipient" => consent.recipient,
      "type" => consent.type,
      "source" => consent.source,
      "status" => consent.status,
      "consentDate" => Calendar.format(consent.consent_at),
      "recipientType" => consent.recipient_type
    }
  end
end
