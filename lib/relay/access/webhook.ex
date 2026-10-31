defmodule Relay.Access.Webhook do
  @moduledoc """
  The shared Suiss webhook profile on the receiving side (E-36, WH-4): the signed content is `webhook-id.webhook-timestamp.body` over the raw bytes, `webhook-signature` lists space separated signatures, and a `v1a` (Ed25519) signature under one of the Access keys of the link verifies the message. Relay shares no secret with Access, so a `v1` (HMAC) signature never verifies. The timestamp must lie within five minutes of the node's clock.
  """

  alias Relay.Access.Jose

  @tolerance_s 300

  @type request :: %{
          required(:webhook_id) => String.t(),
          required(:timestamp) => String.t(),
          required(:signature) => String.t(),
          required(:raw_body) => binary(),
          optional(atom()) => term()
        }

  # E-36
  # E-78
  @doc "Verifies a delivery's signature under the Ed25519 keys of the link at Unix time `now`."
  @spec verify(request(), [Jose.key()], integer()) :: :ok | {:error, Relay.Error.t()}
  def verify(request, keys, now) do
    %{webhook_id: id, timestamp: timestamp, signature: header, raw_body: body} = request
    keys = Enum.filter(keys, &(&1.type == :ed25519))

    with {seconds, ""} <- Integer.parse(timestamp),
         true <- abs(now - seconds) <= @tolerance_s,
         signed = id <> "." <> timestamp <> "." <> body,
         true <- Enum.any?(signatures(header), &signed_by?(&1, signed, keys)) do
      :ok
    else
      _ -> {:error, Relay.Error.new(:auth_invalid_token, "the webhook signature is not valid")}
    end
  end

  defp signed_by?(signature, signed, keys),
    do: Enum.any?(keys, &Jose.valid?(&1, signed, signature))

  defp signatures(header) do
    header
    |> String.split(" ", trim: true)
    |> Enum.flat_map(&signature/1)
  end

  defp signature("v1a," <> encoded) do
    case Base.decode64(encoded) do
      {:ok, signature} -> [signature]
      :error -> []
    end
  end

  defp signature(_other), do: []
end
