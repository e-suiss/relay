defmodule Relay.Channels.Push.Progress do
  @moduledoc """
  The progress surface of an agent's long-running job (AG-52, CH-23): a Live Activity on iOS and a `ProgressStyle` notification on Android, both mapped onto the subject-based collapse model of the push channel. The job is the subject (`Relay.Channels.Push.Collapse`): every update about the same job carries the same collapse key and replaces the one before it, and two jobs never share a surface.

    * APNs: the update is a `liveactivity` push whose `content-state` carries the key and the progress; the application starts the activity under that key and applies later updates to it. A start names the attributes type the SDK registers.
    * FCM: the Android notification `tag` is the key, so the platform replaces the notification of the job in place, and the progress travels in the data payload from which the SDK builds the `ProgressStyle`. The FCM `collapse_key` stays the fixed key of the message class, since a device keeps at most four of them.

  An update holds numbers only: a position, a total and optional segment lengths. It carries no text; what the surface says comes from the template of the notification.
  """

  alias Relay.Channels.Push.Collapse
  alias Relay.Error

  @attributes_type "RelayProgressAttributes"
  @events [:start, :update, :end]
  @segments_max 16

  @typedoc "One progress update of a job: `current` of `total`, optionally split into `segments` whose lengths add up to `total`."
  @type update :: %{
          required(:subject) => Collapse.subject(),
          required(:event) => :start | :update | :end,
          required(:timestamp) => non_neg_integer(),
          required(:current) => non_neg_integer(),
          required(:total) => pos_integer(),
          optional(:segments) => [pos_integer()],
          optional(:indeterminate) => boolean()
        }

  @typedoc "The members to merge into an APNs notification (`Relay.Channels.Push.Apns`) and an FCM message (`Relay.Channels.Push.Fcm`), with the collapse key of the job."
  @type surface :: %{
          topic: String.t(),
          apns: %{push_type: :liveactivity, live_activity: map()},
          fcm: %{collapse_key: String.t(), notification: map(), data: map()}
        }

  # AG-52
  @doc "The attributes type a Live Activity of a job is started with."
  @spec attributes_type() :: String.t()
  def attributes_type, do: @attributes_type

  # AG-52
  # CH-23
  @doc "Maps a progress update onto both platforms under the collapse key of its job; `fcm_collapse_key` is the class key of the priority table."
  @spec surface(update(), String.t()) :: {:ok, surface()} | {:error, Error.t()}
  def surface(%{subject: subject, event: event} = update, fcm_collapse_key)
      when event in @events and is_binary(fcm_collapse_key) do
    with {:ok, state} <- state(update) do
      topic = Collapse.topic(subject)

      {:ok,
       %{
         topic: topic,
         apns: %{push_type: :liveactivity, live_activity: live_activity(update, topic, state)},
         fcm: %{
           collapse_key: fcm_collapse_key,
           notification: %{"tag" => topic},
           data: %{
             "relay_collapse" => topic,
             "relay_progress" => Jason.encode!(Map.put(state, "event", Atom.to_string(event)))
           }
         }
       }}
    end
  end

  def surface(_update, _fcm_collapse_key), do: invalid("a progress update needs its event")

  defp live_activity(%{event: :start} = update, topic, state) do
    update
    |> base(topic, state)
    |> Map.merge(%{attributes_type: @attributes_type, attributes: %{"relay_collapse" => topic}})
  end

  defp live_activity(update, topic, state), do: base(update, topic, state)

  defp base(%{event: event, timestamp: timestamp}, topic, state) do
    %{
      event: event,
      timestamp: timestamp,
      content_state: Map.put(state, "relay_collapse", topic)
    }
  end

  defp state(%{current: current, total: total, timestamp: timestamp} = update)
       when is_integer(current) and is_integer(total) and is_integer(timestamp) and
              timestamp >= 0 and total > 0 and current >= 0 and current <= total do
    with {:ok, segments} <- segments(Map.get(update, :segments), total) do
      {:ok,
       %{
         "current" => current,
         "total" => total,
         "segments" => segments,
         "indeterminate" => Map.get(update, :indeterminate, false) == true
       }}
    end
  end

  defp state(_update), do: invalid("progress is a position from 0 to its total")

  defp segments(nil, total), do: {:ok, [total]}

  defp segments(lengths, total) when is_list(lengths) and length(lengths) in 1..@segments_max do
    if Enum.all?(lengths, &(is_integer(&1) and &1 > 0)) and Enum.sum(lengths) == total,
      do: {:ok, lengths},
      else: invalid("segment lengths are positive and add up to the total")
  end

  defp segments(_other, _total), do: invalid("a progress has 1 to #{@segments_max} segments")

  defp invalid(message), do: {:error, Error.new(:push_progress_invalid, message)}
end
