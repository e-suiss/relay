defmodule Relay.Channels.Email.Tracking do
  @moduledoc """
  Open and click tracking of an e-mail (CH-43, CH-44, CH-76, INV-25). The open pixel and link wrapping are off unless the tenant turns them on, and they are never on for the `security` class or for a message with a security subtype (`email_verification`, `otp_oob`), whatever the tenant's setting. Links the sender wrote, Access's `email_verification` link among them, are passed unchanged and unwrapped when tracking is off; a security e-mail has no redirect chain.
  """

  @type plan :: %{open_pixel: boolean(), wrap_links: boolean()}

  # CH-43
  # CH-44
  # INV-25
  @doc "The tracking of a message: `class`, `security_subtype` (or `nil`) and the tenant's `open_pixel` and `wrap_links` settings, both off when absent."
  @spec plan(map()) :: plan()
  def plan(%{class: class} = message) do
    if untrackable?(class, Map.get(message, :security_subtype)) do
      %{open_pixel: false, wrap_links: false}
    else
      %{
        open_pixel: Map.get(message, :open_pixel, false) == true,
        wrap_links: Map.get(message, :wrap_links, false) == true
      }
    end
  end

  # CH-44
  @doc "Whether no tracking can ever be turned on for a message of `class` with `security_subtype`."
  @spec untrackable?(String.t(), String.t() | nil) :: boolean()
  def untrackable?(class, security_subtype), do: class == "security" or security_subtype != nil
end
