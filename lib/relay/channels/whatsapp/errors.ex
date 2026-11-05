defmodule Relay.Channels.Whatsapp.Errors do
  @moduledoc """
  The WhatsApp error rules beyond the failure class (CH-59). The class of every code comes from the adapter's mapping (`priv/channels/whatsapp_cloud/errors.json`) and drives retry, fallback and cleanup as for every channel (CH-7); these rules add what the class alone cannot say:

    * `131026` (not a WhatsApp user or undeliverable) and `131050` (the user stopped marketing messages) are never retried; `131050` is also written to the preference register (PC-43).
    * `131049` (the per-user marketing cap) is not retried before 24 hours have passed.
    * `131047` (the customer service window is closed) is planned again with the template.
    * `130429` (throughput) slows the number's bucket and `131056` (pair rate) the pair's bucket; both are `transient`.
    * `131057` (the number is in maintenance, as during a throughput upgrade) defers the number's jobs (CH-61).
  """

  @day_ms 24 * 60 * 60 * 1000

  @type follow_up ::
          :never_retry
          | {:not_before_ms, pos_integer()}
          | :replan_with_template
          | :slow_number
          | :slow_pair
          | :number_unavailable
          | :none

  # CH-59
  @doc "The follow-up a WhatsApp error code calls for."
  @spec follow_up(String.t() | nil) :: follow_up()
  def follow_up(code) when code in ["131026", "131050"], do: :never_retry
  def follow_up("131049"), do: {:not_before_ms, @day_ms}
  def follow_up("131047"), do: :replan_with_template
  def follow_up("130429"), do: :slow_number
  def follow_up("131056"), do: :slow_pair
  def follow_up("131057"), do: :number_unavailable
  def follow_up(_code), do: :none

  # CH-59
  # PC-43
  @doc "Returns true when a code is the recipient's marketing opt-out, which the preference register records."
  @spec opt_out?(String.t() | nil) :: boolean()
  def opt_out?(code), do: code == "131050"
end
