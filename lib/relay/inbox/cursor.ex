defmodule Relay.Inbox.Cursor do
  @moduledoc """
  The opaque position of a recipient's stream (IN-22, IN-29): the stream epoch and the sequence number after which a reader continues, written as unpadded base64url of `1.<epoch>.<seq>`. The same text is the `since` of a delta sync and the event identifier of a realtime transport, so a reader resumes from either. It names a position only; the reader's authorization is checked on every read.
  """

  @type t :: %{epoch: pos_integer(), seq: non_neg_integer()}

  # IN-22
  @doc "Writes a position as an opaque cursor."
  @spec encode(t()) :: String.t()
  def encode(%{epoch: epoch, seq: seq}) when is_integer(epoch) and epoch >= 1 and seq >= 0,
    do: Base.url_encode64("1.#{epoch}.#{seq}", padding: false)

  # IN-22
  @doc "Reads an opaque cursor; anything else is `:error`."
  @spec decode(term()) :: {:ok, t()} | :error
  def decode(text) when is_binary(text) and byte_size(text) <= 64 do
    with {:ok, plain} <- Base.url_decode64(text, padding: false),
         ["1", epoch, seq] <- String.split(plain, "."),
         {epoch, ""} when epoch >= 1 <- Integer.parse(epoch),
         {seq, ""} when seq >= 0 <- Integer.parse(seq) do
      {:ok, %{epoch: epoch, seq: seq}}
    else
      _invalid -> :error
    end
  end

  def decode(_text), do: :error
end
