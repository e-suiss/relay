defmodule Relay.Channels.Live.Unsubscribe do
  @moduledoc """
  The unsubscribe URIs of a bulk e-mail (CH-38, PC-35). For a delivery of the marketing and bulk stream the rendered content gains `"unsubscribe"`: the HTTPS one-click URI and the `mailto:` URI that `Relay.Channels.Email` writes as `List-Unsubscribe` and `List-Unsubscribe-Post` and puts in place of the renderer's `unsubscribe_url` placeholder, so the footer link and the header lead to the same link. The URIs come from the module configured as `config :relay, Relay.Channels, unsubscribe: Module` (`links/2` of `Relay.Compliance.Refusals`), which signs a new token for every attempt. Any other e-mail is returned unchanged and never carries the fields.
  """

  # CH-38
  # PC-35
  @doc "The content of an e-mail delivery with its unsubscribe URIs; `{:error, reason}` when a bulk e-mail's links cannot be issued, so the job retries."
  @spec fill(Relay.Scope.t(), map(), binary() | map()) ::
          {:ok, binary() | map()} | {:error, term()}
  def fill(%Relay.Scope{} = scope, delivery, content) do
    with true <- Relay.Channels.bulk_email?(delivery["message_class"]),
         issuer when issuer != nil <- issuer(),
         %{} = decoded <- decoded(content),
         category when is_binary(category) <- delivery["category_key"] || delivery["category"] do
      issue(scope, delivery, decoded, category, issuer)
    else
      _unchanged -> {:ok, content}
    end
  end

  defp issue(scope, delivery, content, category, issuer) do
    to = %{
      recipient_id: delivery["recipient_id"],
      category: category,
      brand_subtenant_id: delivery["subtenant_id"],
      locale: delivery["locale"],
      root: Relay.Channels.public_root()
    }

    case issuer.links(scope, to) do
      {:ok, %{https: https, mailto: mailto}} ->
        unsubscribe = %{"https" => https, "mailto" => mailto}
        {:ok, Jason.encode!(Map.put(content, "unsubscribe", unsubscribe))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decoded(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{} = map} -> map
      _other -> nil
    end
  end

  defp decoded(%{} = content), do: content
  defp decoded(_content), do: nil

  defp issuer, do: :relay |> Application.get_env(Relay.Channels, []) |> Keyword.get(:unsubscribe)
end
