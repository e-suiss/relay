defmodule Relay.Devices.Badge do
  @moduledoc """
  The platform form of the badge number (IN-19, IN-20). The number is the absolute, versioned count the counter write itself returned; it is never an increment and nothing is read again to find it. An uncertain count (a reconciliation running) is `nil`.

  * iOS: `aps.badge` is `min(n, 999)`; an uncertain count leaves the field out, so the badge stays as it is.
  * Android: the notification's `notification_count`; launchers show it differently, so nothing depends on it.
  * Web: a hint the Service Worker passes to `setAppBadge`, used only by an installed PWA.
  """

  @ios_max 999

  @type count :: non_neg_integer() | nil

  # IN-20
  @doc "The badge members of a push to a device of `platform` (`apns`, `fcm`, `hms`, `web_push`, `unified_push`) for a count: the `aps` members of APNs, the Android notification members of FCM and HMS, the data hint of Web Push; empty when the count is uncertain or the platform has no badge."
  @spec members(String.t(), count()) :: map()
  def members(_platform, nil), do: %{}

  def members("apns", n) when is_integer(n) and n >= 0, do: %{"badge" => min(n, @ios_max)}

  def members(platform, n) when platform in ["fcm", "hms"] and is_integer(n) and n >= 0,
    do: %{"notification_count" => n}

  def members("web_push", n) when is_integer(n) and n >= 0, do: %{"badge" => n}
  def members(_platform, _n), do: %{}

  # IN-18
  # IN-20
  @doc "The badge count of counters for the tenant's badge source (`unseen` by default, or `unread`); `nil` when the counters are uncertain or missing."
  @spec count(map() | nil, :unseen | :unread) :: count()
  def count(counters, source \\ :unseen)

  def count(%{uncertain: true}, _source), do: nil
  def count(%{unseen: n}, :unseen) when is_integer(n) and n >= 0, do: n
  def count(%{unread: n}, :unread) when is_integer(n) and n >= 0, do: n
  def count(_counters, _source), do: nil
end
