defmodule Relay.Access.Pairing.Streams do
  @moduledoc """
  Relay's SSF push stream from Access (E-101, E-94, Access OP-149 m.17 (e)): a stream as `platform_streams` shows it, the stream Relay adopts, what Relay does about each status and the request that opens it again. Relay never deletes a stream.

  A stream pushes to Relay when its delivery method is RFC 8935 push and its endpoint is Relay's receiver (`POST /v1/access/events`). Of several, Relay adopts an enabled one, else any that is not disabled. Enabled is up; paused or unreachable is only an operator warning, since there is no resume; missing or disabled is opened again, asking for every event a known stream supports, or for Access's catalog when no stream is left to read it from.
  """

  alias Relay.Access.Pairing.Target

  @push "urn:ietf:rfc:8935"
  @statuses %{
    "enabled" => :enabled,
    "paused" => :paused,
    "disabled" => :disabled,
    "unreachable" => :unreachable
  }
  @catalog ~w(
    urn:suiss:access:event:api_client.created
    urn:suiss:access:event:api_client.disabled
    urn:suiss:access:event:api_client.updated
    urn:suiss:access:event:authority-expired
    urn:suiss:access:event:authority-narrowed
    urn:suiss:access:event:authority-revoked
    urn:suiss:access:event:instance-terminated
    urn:suiss:access:event:mandate-ended
    urn:suiss:access:event:organization.created
    urn:suiss:access:event:organization.updated
    urn:suiss:access:event:party.compromised
    urn:suiss:access:event:party.disabled
    urn:suiss:access:event:projection-invalidated
    urn:suiss:access:event:revalidation-required
    urn:suiss:access:event:tenant.created
  )

  @type status :: :enabled | :paused | :disabled | :unreachable
  @type t :: %{
          id: String.t(),
          status: status(),
          method: String.t() | nil,
          endpoint: String.t() | nil,
          events_supported: [String.t()]
        }

  @doc "Access's event catalog, asked for when no stream is left to read `events_supported` from."
  @spec catalog() :: [String.t(), ...]
  def catalog, do: @catalog

  # E-101
  @doc "Reads one stream."
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(%{"stream_id" => id, "status" => status} = stream) do
    delivery = if is_map(stream["delivery"]), do: stream["delivery"], else: %{}

    with true <- Target.uuid?(id),
         {:ok, status} <- Map.fetch(@statuses, status) do
      {:ok,
       %{
         id: id,
         status: status,
         method: text(delivery["method"]),
         endpoint: text(delivery["endpoint_url"]),
         events_supported: events(stream["events_supported"])
       }}
    else
      _invalid -> :error
    end
  end

  def parse(_stream), do: :error

  # E-101
  @doc "Reads `GET <platform_streams>`."
  @spec parse_list(term()) :: {:ok, [t()]} | :error
  def parse_list(%{"streams" => streams}) when is_list(streams) do
    parsed = Enum.map(streams, &parse/1)

    if Enum.all?(parsed, &match?({:ok, _stream}, &1)),
      do: {:ok, Enum.map(parsed, &elem(&1, 1))},
      else: :error
  end

  def parse_list(_document), do: :error

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp events(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp events(_list), do: []

  @doc "Whether a stream pushes to `receiver`."
  @spec pushes_to?(t(), String.t()) :: boolean()
  def pushes_to?(stream, receiver), do: stream.method == @push and stream.endpoint == receiver

  # E-101
  @doc "The stream Relay adopts among `streams`: one that pushes to `receiver` and is enabled, else one that pushes to it and is not disabled."
  @spec live([t()], String.t()) :: t() | nil
  def live(streams, receiver) do
    pushing = Enum.filter(streams, &pushes_to?(&1, receiver))

    Enum.find(pushing, &(&1.status == :enabled)) ||
      Enum.find(pushing, &(&1.status != :disabled))
  end

  # E-101
  @doc "What Relay does about the stream it read, `nil` when there is none: `:up`, `{:down, status}` for paused or unreachable, `:reopen` for missing or disabled."
  @spec check(t() | nil) :: :up | {:down, status()} | :reopen
  def check(%{status: :enabled}), do: :up
  def check(%{status: status}) when status in [:paused, :unreachable], do: {:down, status}
  def check(_missing_or_disabled), do: :reopen

  # E-101
  @doc "The events a new stream asks for: what a known stream supports, else Access's catalog."
  @spec requested([t()]) :: [String.t(), ...]
  def requested(streams) do
    case Enum.find(streams, &(&1.events_supported != [])) do
      %{events_supported: events} -> events
      nil -> @catalog
    end
  end

  # E-101
  @doc "The body of `POST <platform_streams>` that opens a push stream to `receiver` for Relay's Access `client_id`."
  @spec create_body(String.t(), String.t(), [String.t()]) :: map()
  def create_body(receiver, client_id, events) do
    %{
      "delivery" => %{"method" => @push, "endpoint_url" => receiver},
      "aud" => client_id,
      "events_requested" => events
    }
  end
end
