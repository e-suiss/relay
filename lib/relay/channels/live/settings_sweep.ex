defmodule Relay.Channels.Live.SettingsSweep do
  @moduledoc """
  The periodic provider settings check (CH-52). Every hour on the `maintenance` queue it checks the verified provider accounts whose settings were last checked more than six hours ago, at most five accounts in each of at most twenty scopes (`Relay.Channels.Live.SettingsCheck.sweep/3`); a scope with more due accounts is picked up again by the next run. A mismatch drops the account from the verified route with the `provider_account.settings_mismatched` event; nothing is verified again by this job.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 900_000

  @interval_s 21_600
  @scopes 20
  @accounts 5

  # CH-52
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = Relay.Channels.Live.SettingsCheck.sweep(@interval_s, @scopes, @accounts)
    :ok
  end
end
