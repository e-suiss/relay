defmodule Relay.Channels.SmsSender do
  @moduledoc """
  The rules of an SMS sender identity (CH-50, CH-14). A sender identity is a tenant (and sub-tenant) entity with a type, a country and an approval state per provider account; its fields are string keys as the store reads them:

    * `sender_type`: `alphanumeric`, `short_code`, `long_number`, `toll_free` or `ten_dlc`; `value` the header or number; `country` its ISO 3166-1 alpha-2 country; `approval_state` (`pending`, `approved`, `rejected`) and `suspended_at`;
    * TR: `iys_brand_code`, the İYS brand the header belongs to (one brand, one header, one `brandCode`);
    * US: `us_brand_id`, `us_campaign_id` and `us_use_case` of a 10DLC registration; `tfv_state` and `brn` (Business Registration Number) of a toll-free number.

  `validate/1` holds the rules of the identity itself, checked when it is registered and again before every send; `check/2` adds what depends on the send. A broken rule returns its `rule_id`: nothing is sent with an identity that is not approved, and a message class that the 10DLC campaign's use case does not cover is refused (a marketing message on a 2FA campaign).

  TR alphanumeric headers have 3 to 11 characters, are not only digits and are never a generic name such as `BANKA` or `KARGO`, compared after Turkish case folding.
  """

  @types ~w(alphanumeric short_code long_number toll_free ten_dlc)
  @generic ~w(BANKA KARGO)
  @registration ~w(iys_brand_code us_brand_id us_campaign_id us_use_case tfv_state brn)
  @use_cases %{
    "2FA" => ~w(security),
    "SECURITY_ALERT" => ~w(security),
    "FRAUD_ALERT" => ~w(security),
    "ACCOUNT_NOTIFICATION" => ~w(transactional operational action_required system),
    "CUSTOMER_CARE" => ~w(transactional operational action_required),
    "DELIVERY_NOTIFICATION" => ~w(transactional operational),
    "MARKETING" => ~w(marketing),
    "MIXED" => ~w(security transactional operational social marketing system action_required),
    "LOW_VOLUME" => ~w(security transactional operational social marketing system action_required)
  }

  @type identity :: %{required(String.t()) => term()}

  @doc "The sender identity types."
  @spec types() :: [String.t(), ...]
  def types, do: @types

  @doc "The registration fields an SMS sender identity keeps."
  @spec registration_fields() :: [String.t(), ...]
  def registration_fields, do: @registration

  @doc "The identity the rules read, from a stored sender identity row (`value`, `country`, `approval_state`, `suspended_at`, `sms_type`, `registration`); a row without an approval state is an approved one, as the route reads only those."
  @spec identity(map()) :: identity()
  def identity(row), do: identity(row, row["sms_type"], row["registration"] || %{})

  @doc "The identity the rules read, from a stored row with the given type and registration."
  @spec identity(map(), String.t() | nil, map()) :: identity()
  def identity(row, type, registration) do
    registration
    |> Map.take(@registration)
    |> Map.merge(%{
      "sender_type" => type,
      "value" => row["value"],
      "country" => row["country"],
      "approval_state" => row["approval_state"] || "approved",
      "suspended_at" => row["suspended_at"]
    })
  end

  @doc "The 10DLC use cases and the message classes each covers."
  @spec use_cases() :: %{String.t() => [String.t()]}
  def use_cases, do: @use_cases

  # CH-50
  @doc "Checks the rules of an identity itself: its type, the TR header rules and İYS brand, and the US 10DLC and toll-free registration."
  @spec validate(identity()) :: :ok | {:error, String.t()}
  def validate(identity) do
    type = identity["sender_type"]
    country = identity["country"]

    cond do
      type not in @types -> {:error, "channel.sender_invalid"}
      country == "TR" -> turkish(identity, type)
      country == "US" -> american(identity, type)
      true -> :ok
    end
  end

  defp turkish(identity, "alphanumeric") do
    value = identity["value"] || ""

    cond do
      not header?(value) -> {:error, "channel.sender_invalid"}
      generic?(value) -> {:error, "channel.sender_generic"}
      blank?(identity["iys_brand_code"]) -> {:error, "channel.sender_iys_missing"}
      true -> :ok
    end
  end

  defp turkish(identity, _type) do
    if blank?(identity["iys_brand_code"]), do: {:error, "channel.sender_iys_missing"}, else: :ok
  end

  defp american(identity, "ten_dlc") do
    registered =
      not blank?(identity["us_brand_id"]) and not blank?(identity["us_campaign_id"]) and
        Map.has_key?(@use_cases, identity["us_use_case"])

    if registered, do: :ok, else: {:error, "channel.sender_unregistered"}
  end

  defp american(identity, "toll_free") do
    if identity["tfv_state"] == "verified" and not blank?(identity["brn"]),
      do: :ok,
      else: {:error, "channel.sender_unregistered"}
  end

  defp american(_identity, _type), do: :ok

  # CH-50
  @doc "Returns true when a header has 3 to 11 characters and not only digits."
  @spec header?(String.t()) :: boolean()
  def header?(value) when is_binary(value) do
    length = String.length(value)
    length in 3..11 and not Regex.match?(~r/\A[0-9]+\z/, value)
  end

  # CH-50
  @doc "Returns true when a header is a generic name, after Turkish case folding and without spaces."
  @spec generic?(String.t()) :: boolean()
  def generic?(value) when is_binary(value) do
    folded =
      value
      |> String.replace(["i", "ı"], fn
        "i" -> "İ"
        "ı" -> "I"
      end)
      |> String.upcase()
      |> String.replace(~r/[\s.\-_]/u, "")
      |> String.replace("İ", "I")

    folded in @generic
  end

  # CH-50
  # CH-14
  @doc "Checks an identity before a send of `message_class`: approved and not suspended, its own rules, and a 10DLC campaign whose use case covers the class."
  @spec check(identity(), String.t() | nil) :: :ok | {:error, String.t()}
  def check(identity, message_class) do
    cond do
      identity["approval_state"] != "approved" -> {:error, "channel.sender_unapproved"}
      not is_nil(identity["suspended_at"]) -> {:error, "channel.sender_unapproved"}
      true -> with :ok <- validate(identity), do: campaign(identity, message_class)
    end
  end

  defp campaign(%{"country" => "US", "sender_type" => "ten_dlc"} = identity, class) do
    if class in Map.get(@use_cases, identity["us_use_case"], []),
      do: :ok,
      else: {:error, "channel.sender_campaign_mismatch"}
  end

  defp campaign(_identity, _class), do: :ok

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
