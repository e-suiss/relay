defmodule RelayDev.Credo.NoDirectClock do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: "Time and randomness come only from `Relay.Clock` and `Relay.Random` (T-57)."
    ]

  @message "use Relay.Clock or Relay.Random instead (T-57)"

  @rules [
    {DateTime, :utc_now, @message},
    {NaiveDateTime, :utc_now, @message},
    {NaiveDateTime, :local_now, @message},
    {Date, :utc_today, @message},
    {Time, :utc_now, @message},
    {System, :system_time, @message},
    {System, :os_time, @message},
    {System, :monotonic_time, @message},
    {:os, :system_time, @message},
    {:os, :timestamp, @message},
    {:erlang, :system_time, @message},
    {:erlang, :monotonic_time, @message},
    {:erlang, :now, @message},
    {:rand, :_, @message},
    {:random, :_, @message},
    {:crypto, :strong_rand_bytes, @message},
    {Enum, :random, @message},
    {Enum, :shuffle, @message},
    {Enum, :take_random, @message}
  ]

  # T-57
  @impl true
  def run(%SourceFile{} = source_file, params),
    do: RelayDev.Credo.Calls.issues(source_file, params, __MODULE__, @rules)
end
