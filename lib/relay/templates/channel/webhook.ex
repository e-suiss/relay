defmodule Relay.Templates.Channel.Webhook do
  @moduledoc """
  Webhook output (TP-9, TP-24). A webhook variant in restricted mode is a JSON body template; its rendered output must be one JSON object or array. The rendered text is sent as it is, so validation never changes content; the decoded value is returned for inspection.
  """

  alias Relay.Templates.Finding

  @type output :: %{body: String.t(), data: map() | list(), bytes: non_neg_integer()}
  @type result :: {:ok, %{output: output(), changes: []}} | {:error, [Finding.t()]}

  # TP-9
  # TP-24
  @doc "Validates a rendered JSON body; `opts` takes `:locale`."
  @spec render(binary(), keyword()) :: result()
  def render(body, opts \\ []) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} when is_map(data) or is_list(data) ->
        {:ok, %{output: %{body: body, data: data, bytes: byte_size(body)}, changes: []}}

      {:ok, _scalar} ->
        {:error, [finding(:webhook_body_type, %{}, opts)]}

      {:error, %Jason.DecodeError{position: position}} ->
        {:error, [finding(:webhook_json, %{position: position}, opts)]}
    end
  end

  defp finding(check, detail, opts) do
    locale = Keyword.get(opts, :locale)
    Finding.new(check, :hard, channel: :webhook, locale: locale, pointer: "", detail: detail)
  end
end
