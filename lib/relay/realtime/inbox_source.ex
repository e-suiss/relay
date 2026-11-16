defmodule Relay.Realtime.InboxSource do
  @moduledoc """
  The default stream source: the subscriber's inbox (IN-22, IN-29). It asks the inbox context (`Relay.Inbox`, or the module set as `config :relay, Relay.Realtime.InboxSource, inbox: module`) for the stream's signal topic (`signal_topic`), its head cursor (`cursor`), the changes after a cursor (`changes`) and the badge counters (`counters`), each taking the scope and the subscriber first.
  """

  @behaviour Relay.Realtime.Source

  # IN-24
  @impl true
  def signal_topic(scope, subscriber_id), do: inbox().signal_topic(scope, subscriber_id)

  # IN-22
  @impl true
  def head(scope, subscriber_id), do: inbox().cursor(scope, subscriber_id)

  # IN-29
  @impl true
  def changes(scope, subscriber_id, cursor, limit),
    do: inbox().changes(scope, subscriber_id, cursor, limit)

  # IN-26
  @impl true
  def counters(scope, subscriber_id), do: inbox().counters(scope, subscriber_id)

  defp inbox do
    :relay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:inbox, Relay.Inbox)
  end
end
