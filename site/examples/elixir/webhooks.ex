defmodule DocsExamples.Webhooks do
  @moduledoc false

  # #region verify
  def handle(headers, raw_body) do
    keys = [System.fetch_env!("RELAY_WEBHOOK_KEY")]

    case EsuissRelay.Webhook.verify(headers, raw_body, keys) do
      {:ok, %{id: id}} ->
        if first_time?(id), do: process(JSON.decode!(raw_body))
        {204, ""}

      {:error, _reason} ->
        {400, ""}
    end
  end
  # #endregion verify

  defp first_time?(id), do: is_binary(id)

  defp process(event), do: IO.puts("received #{event["type"]}")
end
