defmodule Relay.Compliance.IysChannel do
  @moduledoc """
  The İYS channel of a Relay channel (PC-27, CH-56): İYS keeps a commercial consent per brand and one of its three channels, `MESAJ` (SMS), `ARAMA` (voice calls) and `EPOSTA` (e-mail). A commercial voice message is subject to `ARAMA` exactly as a commercial SMS is subject to `MESAJ`. Every other Relay channel has no İYS channel and takes no İYS step.
  """

  @channels %{"sms" => "MESAJ", "voice" => "ARAMA", "email" => "EPOSTA"}

  @type t :: String.t()

  # CH-56
  # PC-27
  @doc "The İYS channel of a Relay channel, given by name or as an atom: `{:ok, \"MESAJ\"}` for `sms`, `{:ok, \"ARAMA\"}` for `voice`, `{:ok, \"EPOSTA\"}` for `email`, `:none` for a channel İYS does not cover."
  @spec of(String.t() | atom()) :: {:ok, t()} | :none
  def of(channel) when is_atom(channel) and not is_nil(channel), do: of(Atom.to_string(channel))

  def of(channel) do
    case Map.fetch(@channels, channel) do
      {:ok, iys} -> {:ok, iys}
      :error -> :none
    end
  end

  # CH-56
  @doc "Returns true when a Relay channel has an İYS channel."
  @spec covered?(String.t() | atom()) :: boolean()
  def covered?(channel), do: of(channel) != :none

  @doc "The three İYS channels."
  @spec all() :: [t(), ...]
  def all, do: ["ARAMA", "EPOSTA", "MESAJ"]

  # CH-56
  @doc "The Relay channels subject to an İYS channel, sorted."
  @spec channels() :: [String.t(), ...]
  def channels, do: @channels |> Map.keys() |> Enum.sort()
end
