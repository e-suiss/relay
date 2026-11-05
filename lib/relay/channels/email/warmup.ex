defmodule Relay.Channels.Email.Warmup do
  @moduledoc """
  Warm-up of a new sending domain or IP address (CH-42), on a plan of the `email_warmup_plans` data set. Day 1 is the day sending started; the step in force is the last one whose `from_day` has come, and after `until_day` the plan is complete and puts no cap. The step caps the mail of the day and, per recipient domain, the mail of the hour; a step's `domains` row overrides the hourly cap of that recipient domain. A provider's own warm-up caps are merged by taking the lower cap. Mail over the plan is deferred, never refused.
  """

  @type usage :: %{
          sent_today: non_neg_integer(),
          sent_this_hour: non_neg_integer(),
          recipient_domain: String.t()
        }
  @type provider_caps :: %{
          optional(:daily_cap) => pos_integer(),
          optional(:domain_hourly_cap) => pos_integer()
        }
  @type allowance ::
          :complete | {:allow, pos_integer()} | {:defer, :daily_cap | :domain_hourly_cap}

  # CH-42
  @doc "The day number of `today` in a plan that started on `started_on`; day 1 is the start day."
  @spec day(Date.t(), Date.t()) :: integer()
  def day(%Date{} = started_on, %Date{} = today), do: Date.diff(today, started_on) + 1

  # CH-42
  @doc """
  How many more e-mails may go now to `usage.recipient_domain`: `{:allow, n}`, `{:defer, cap}` naming the cap that is reached, or `:complete` once the plan is over. `usage` carries the mail already sent today and, to the recipient domain, this hour.
  """
  @spec allowance(map(), Date.t(), Date.t(), usage(), provider_caps()) :: allowance()
  def allowance(plan, %Date{} = started_on, %Date{} = today, usage, provider_caps \\ %{}) do
    day = day(started_on, today)

    case step(plan, day) do
      nil ->
        :complete

      step ->
        domain = String.downcase(usage.recipient_domain, :ascii)
        daily = min_cap(step["daily_cap"], Map.get(provider_caps, :daily_cap))
        hourly = step |> Map.get("domains", %{}) |> Map.get(domain, step["domain_hourly_cap"])
        hourly = min_cap(hourly, Map.get(provider_caps, :domain_hourly_cap))
        decide(daily - usage.sent_today, hourly - usage.sent_this_hour)
    end
  end

  defp step(%{"until_day" => until_day, "steps" => steps}, day)
       when day >= 1 and day <= until_day do
    steps
    |> Enum.filter(&(&1["from_day"] <= day))
    |> Enum.max_by(& &1["from_day"], fn -> nil end)
  end

  defp step(_plan, _day), do: nil

  defp min_cap(cap, nil), do: cap
  defp min_cap(cap, provider), do: min(cap, provider)

  defp decide(daily_left, _hourly_left) when daily_left <= 0, do: {:defer, :daily_cap}
  defp decide(_daily_left, hourly_left) when hourly_left <= 0, do: {:defer, :domain_hourly_cap}
  defp decide(daily_left, hourly_left), do: {:allow, min(daily_left, hourly_left)}
end
