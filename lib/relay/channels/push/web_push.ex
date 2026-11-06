defmodule Relay.Channels.Push.WebPush do
  @moduledoc """
  Web Push requests (RFC 8030) and payloads. A request carries the `aes128gcm` encrypted body (`Relay.Channels.Push.WebPush.Encryption`), the VAPID `Authorization` header (`Relay.Channels.Push.WebPush.Vapid`; a UnifiedPush distributor may take none), `TTL`, `Urgency` and an optional `Topic`. There is no silent Web Push: a message without an urgency (the `system` class) is refused (CH-26).

  Two payload forms are built: the classic form, a JSON object the application's service worker reads, and the Declarative Web Push form, which the browser shows without a service worker (CH-26, T-38).
  """

  alias Relay.Channels.Push.WebPush.Encryption
  alias Relay.Error

  @urgencies %{very_low: "very-low", low: "low", normal: "normal", high: "high"}
  @topic ~r/\A[A-Za-z0-9_-]{1,32}\z/
  @declarative_magic 8030
  @dirs ["auto", "ltr", "rtl"]

  @type urgency :: :very_low | :low | :normal | :high

  @typedoc "A push to one subscription."
  @type push :: %{
          required(:endpoint) => String.t(),
          required(:p256dh) => Encryption.public_key(),
          required(:auth) => <<_::128>>,
          required(:payload) => binary(),
          required(:ttl) => non_neg_integer(),
          required(:urgency) => urgency() | nil,
          required(:authorization) => String.t() | nil,
          optional(:topic) => String.t() | nil
        }

  @typedoc "An HTTP request for the adapter's client."
  @type request :: %{
          method: :post,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  # CH-26
  # CH-9
  @doc "Builds the request of one push, encrypting the payload with a fresh ephemeral key."
  @spec request(push()) :: {:ok, request()} | {:error, Error.t()}
  def request(%{urgency: nil}),
    do: {:error, Error.new(:web_push_silent, "Web Push carries no silent message")}

  def request(%{endpoint: endpoint, p256dh: p256dh, auth: auth, payload: payload} = push)
      when is_binary(payload) do
    with :ok <- ttl(push.ttl),
         {:ok, urgency} <- urgency(push.urgency),
         {:ok, topic} <- topic(Map.get(push, :topic)),
         {:ok, body} <- Encryption.encrypt(payload, p256dh, auth) do
      base = [
        {"content-encoding", "aes128gcm"},
        {"content-type", "application/octet-stream"},
        {"ttl", Integer.to_string(push.ttl)},
        {"urgency", urgency}
      ]

      headers = authorization(push.authorization) ++ base ++ topic

      {:ok, %{method: :post, url: endpoint, headers: headers, body: body}}
    end
  end

  defp authorization(nil), do: []
  defp authorization(value) when is_binary(value), do: [{"authorization", value}]

  defp ttl(ttl) when is_integer(ttl) and ttl >= 0, do: :ok
  defp ttl(_ttl), do: {:error, Error.new(:web_push_ttl_invalid, "TTL is a non-negative integer")}

  defp urgency(urgency) when is_map_key(@urgencies, urgency),
    do: {:ok, Map.fetch!(@urgencies, urgency)}

  defp urgency(_urgency), do: {:error, Error.new(:web_push_urgency_invalid, "unknown urgency")}

  defp topic(nil), do: {:ok, []}

  defp topic(topic) when is_binary(topic) do
    if Regex.match?(@topic, topic),
      do: {:ok, [{"topic", topic}]},
      else: {:error, Error.new(:web_push_topic_invalid, "Topic is 1 to 32 base64url characters")}
  end

  # CH-26
  @doc "The classic payload: the JSON encoding of `data` for the service worker."
  @spec classic(map()) :: {:ok, binary()} | {:error, Error.t()}
  def classic(data) when is_map(data) do
    case Jason.encode(data) do
      {:ok, json} -> fits(json)
      {:error, _reason} -> {:error, Error.new(:push_payload_invalid, "not JSON encodable")}
    end
  end

  # CH-26
  # T-38
  @doc """
  The Declarative Web Push payload. `notification` takes `title` and `navigate` (an HTTPS URL), both required, and optionally `body`, `lang`, `dir`, `tag`, `silent`, `app_badge` (a non-negative integer), `data` and `actions` (each with `title`, `action` and `navigate`). `mutable: true` lets the service worker change the notification before it is shown.
  """
  @spec declarative(map(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def declarative(notification, opts \\ []) when is_map(notification) do
    with {:ok, fields} <- notification(notification) do
      members = [{"web_push", @declarative_magic}, {"notification", ordered(fields)}]
      mutable = if Keyword.get(opts, :mutable, false), do: [{"mutable", true}], else: []

      (members ++ mutable)
      |> Jason.OrderedObject.new()
      |> Jason.encode!()
      |> fits()
    end
  end

  defp notification(%{title: title, navigate: navigate} = n)
       when is_binary(title) and title != "" and is_binary(navigate) do
    with :ok <- https(navigate),
         {:ok, actions} <- actions(Map.get(n, :actions, [])),
         :ok <- dir(Map.get(n, :dir)) do
      optional =
        for key <- [:body, :lang, :dir, :tag, :silent, :data],
            Map.get(n, key) != nil,
            do: {Atom.to_string(key), Map.fetch!(n, key)}

      required = [{"title", title}, {"navigate", navigate}]
      {:ok, required ++ optional ++ badge(Map.get(n, :app_badge)) ++ actions}
    end
  end

  defp notification(_notification),
    do: {:error, Error.new(:push_payload_invalid, "a declarative push needs title and navigate")}

  defp ordered(fields), do: Jason.OrderedObject.new(fields)

  defp badge(nil), do: []
  defp badge(count) when is_integer(count) and count >= 0, do: [{"app_badge", "#{count}"}]
  defp badge(_count), do: []

  defp dir(nil), do: :ok
  defp dir(dir) when dir in @dirs, do: :ok
  defp dir(_dir), do: {:error, Error.new(:push_payload_invalid, "dir is auto, ltr or rtl")}

  defp actions([]), do: {:ok, []}

  defp actions(actions) when is_list(actions) do
    case Enum.reduce_while(actions, {:ok, []}, &action/2) do
      {:ok, list} -> {:ok, [{"actions", list}]}
      error -> error
    end
  end

  defp actions(_actions), do: malformed_action()

  defp action(%{title: title, action: action, navigate: navigate}, {:ok, acc})
       when is_binary(title) and is_binary(action) and is_binary(navigate) do
    case https(navigate) do
      :ok ->
        member = [{"action", action}, {"title", title}, {"navigate", navigate}]
        {:cont, {:ok, acc ++ [ordered(member)]}}

      error ->
        {:halt, error}
    end
  end

  defp action(_action, _acc), do: {:halt, malformed_action()}

  defp malformed_action, do: {:error, Error.new(:push_payload_invalid, "an action is malformed")}

  defp https(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      _other -> {:error, Error.new(:push_payload_invalid, "navigate is an HTTPS URL")}
    end
  end

  defp fits(json) do
    if byte_size(json) <= Encryption.max_plaintext(),
      do: {:ok, json},
      else: {:error, too_large(byte_size(json))}
  end

  defp too_large(bytes) do
    Error.new(:push_payload_too_large, "the Web Push message is too large", %{
      bytes: bytes,
      limit: Encryption.max_plaintext()
    })
  end
end
