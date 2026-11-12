defmodule Relay.Inbox.Cursor do
  @moduledoc """
  The opaque position of a recipient's stream (IN-22, IN-29): the stream epoch and the sequence number after which a reader continues, and the announcement sequence of the scope the reader has seen (IN-3), written as unpadded base64url of `2.<epoch>.<seq>.<announcements>`. A cursor of the first form, `1.<epoch>.<seq>`, reads with announcement sequence 0. The same text is the `since` of a delta sync and the event identifier of a realtime transport, so a reader resumes from either. It names a position only; the reader's authorization is checked on every read.
  """

  @type t :: %{
          required(:epoch) => pos_integer(),
          required(:seq) => non_neg_integer(),
          optional(:ann) => non_neg_integer()
        }

  # IN-22
  # IN-3
  @doc "Writes a position as an opaque cursor."
  @spec encode(t()) :: String.t()
  def encode(%{epoch: epoch, seq: seq} = position)
      when is_integer(epoch) and epoch >= 1 and seq >= 0 do
    ann = Map.get(position, :ann, 0)
    true = is_integer(ann) and ann >= 0
    Base.url_encode64("2.#{epoch}.#{seq}.#{ann}", padding: false)
  end

  # IN-22
  # IN-3
  @doc "Reads an opaque cursor; anything else is `:error`."
  @spec decode(term()) :: {:ok, t()} | :error
  def decode(text) when is_binary(text) and byte_size(text) <= 64 do
    with {:ok, plain} <- Base.url_decode64(text, padding: false),
         [epoch, seq, ann] <- parts(String.split(plain, ".")),
         {epoch, ""} when epoch >= 1 <- Integer.parse(epoch),
         {seq, ""} when seq >= 0 <- Integer.parse(seq),
         {ann, ""} when ann >= 0 <- Integer.parse(ann) do
      {:ok, %{epoch: epoch, seq: seq, ann: ann}}
    else
      _invalid -> :error
    end
  end

  def decode(_text), do: :error

  defp parts(["1", epoch, seq]), do: [epoch, seq, "0"]
  defp parts(["2", epoch, seq, ann]), do: [epoch, seq, ann]
  defp parts(_other), do: :error
end
