defmodule Relay.Channels.Email.Streams do
  @moduledoc """
  E-mail stream separation and the sender identity (CH-35). The `security`, `transactional`, `operational` and `action_required` classes go out on the `transactional` stream; `marketing` and `social` digests on the `marketing` stream. The two streams use their own IP pool and queue, and each has its own sender identity: from address, sending domain, DKIM selector and return path domain. A category may name its own from address and sending domain on its class's stream; a sending domain is never shared between the streams. The `system` class has no e-mail stream.

  A configuration is a map with `"streams"` (`"transactional"` and `"marketing"`, each with `"from"`, `"domain"`, `"selector"`, `"return_path_domain"`, `"ip_pool"` and `"queue"`) and optional `"categories"` (category key ⇒ its `"class"` and optional `"from"` and `"domain"`).
  """

  alias Relay.Error

  @transactional ["security", "transactional", "operational", "action_required"]
  @marketing ["marketing", "social"]
  @streams ["transactional", "marketing"]
  @stream_fields ["from", "domain", "selector", "return_path_domain", "ip_pool", "queue"]

  @type stream :: String.t()

  # CH-35
  @doc "The e-mail stream of a message class."
  @spec stream(String.t()) :: {:ok, stream()} | {:error, Error.t()}
  def stream(class) when class in @transactional, do: {:ok, "transactional"}
  def stream(class) when class in @marketing, do: {:ok, "marketing"}

  def stream(_class),
    do: {:error, Error.new(:no_email_stream, "the message class has no e-mail stream")}

  @doc "Whether a class goes out on the marketing and bulk stream."
  @spec bulk?(String.t()) :: boolean()
  def bulk?(class), do: class in @marketing

  # CH-35
  @doc "Checks a stream configuration: both streams are complete, and they share no IP pool, queue, sending domain or DKIM selector, and no category's sending domain belongs to the other stream."
  @spec validate(map()) :: :ok | {:error, Error.t()}
  def validate(%{"streams" => streams} = config) when is_map(streams) do
    with :ok <- complete(streams),
         :ok <- separate(streams),
         do: categories(Map.get(config, "categories", %{}), streams)
  end

  def validate(_config), do: invalid("a stream configuration has both streams")

  defp complete(streams) do
    complete? =
      Enum.all?(@streams, fn name ->
        Enum.all?(@stream_fields, &present?(field(streams, name, &1)))
      end)

    if complete?,
      do: :ok,
      else: invalid("a stream configuration names every field of both streams")
  end

  defp field(streams, name, key) do
    case streams do
      %{^name => %{^key => value}} -> value
      _other -> nil
    end
  end

  defp separate(streams) do
    shared =
      Enum.filter(["ip_pool", "queue", "domain", "selector"], fn key ->
        lower(field(streams, "transactional", key)) == lower(field(streams, "marketing", key))
      end)

    case shared do
      [] -> :ok
      keys -> invalid("the streams share " <> Enum.join(keys, ", "))
    end
  end

  defp categories(categories, streams) when is_map(categories) do
    clash? =
      Enum.any?(categories, fn {_key, category} ->
        case stream(category["class"] || "") do
          {:ok, own} -> lower(category["domain"]) == lower(field(streams, other(own), "domain"))
          {:error, _error} -> true
        end
      end)

    if clash?,
      do: invalid("a category names its class and no sending domain of the other stream"),
      else: :ok
  end

  defp categories(_categories, _streams), do: invalid("categories is a map")

  defp other("transactional"), do: "marketing"
  defp other("marketing"), do: "transactional"

  # CH-35
  @doc "The sender identity of a message: its class's stream, overridden by the category's `from` and `domain` when the category names them."
  @spec sender(map(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, Error.t()}
  def sender(%{"streams" => streams} = config, class, category_key) do
    with {:ok, stream} <- stream(class) do
      base = Map.fetch!(streams, stream)
      category = config |> Map.get("categories", %{}) |> Map.get(category_key || "", %{})

      {:ok,
       %{
         stream: stream,
         from: category["from"] || base["from"],
         domain: category["domain"] || base["domain"],
         selector: base["selector"],
         return_path_domain: base["return_path_domain"],
         ip_pool: base["ip_pool"],
         queue: base["queue"]
       }}
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp lower(value) when is_binary(value), do: String.downcase(value, :ascii)
  defp lower(_value), do: nil

  defp invalid(message), do: {:error, Error.new(:invalid_email_streams, message)}
end
