defmodule Relay.Channels.Whatsapp.Window do
  @moduledoc """
  The WhatsApp customer service window (CSW, CH-58). The window is kept per recipient × business number and every inbound message from the recipient opens it again for 24 hours from the message's own time. While it is open a free-form message may be sent; once it is closed only a template may. The window says nothing about price: a message inside it is never assumed free, its cost comes from the rate card (`Relay.Channels.Whatsapp.Pricing`, CH-18).

  A window whose state cannot be read is closed: the template is always allowed, and a free-form message sent into a window Meta has closed comes back as `131047` and is planned again with the template (CH-59).
  """

  @window_ms 24 * 60 * 60 * 1000

  @type state :: %{last_inbound_at: DateTime.t()} | nil

  @doc "The length of the window in milliseconds."
  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms

  # CH-58
  @doc "The state after an inbound message at `at`: the later of the two inbound times wins, so a late or repeated webhook never shortens the window."
  @spec refresh(state(), DateTime.t()) :: %{last_inbound_at: DateTime.t()}
  def refresh(nil, %DateTime{} = at), do: %{last_inbound_at: at}

  def refresh(%{last_inbound_at: last} = state, %DateTime{} = at) do
    if DateTime.after?(at, last), do: %{state | last_inbound_at: at}, else: state
  end

  # CH-58
  @doc "Returns true while the window is open at `now`."
  @spec open?(state(), DateTime.t()) :: boolean()
  def open?(nil, _now), do: false

  def open?(%{last_inbound_at: last}, %DateTime{} = now),
    do: DateTime.diff(now, last, :millisecond) < @window_ms

  # CH-58
  @doc "When an open window closes, or `nil` for a closed one."
  @spec closes_at(state(), DateTime.t()) :: DateTime.t() | nil
  def closes_at(state, now) do
    if open?(state, now),
      do: DateTime.add(state.last_inbound_at, @window_ms, :millisecond),
      else: nil
  end

  # CH-58
  @doc "Chooses the kind of a message from the window and the kinds its content offers: free-form only in an open window, the template otherwise; `{:error, :window_closed}` when the window is closed and the content has no template."
  @spec choose(boolean(), [Relay.Channels.Whatsapp.Message.kind()]) ::
          {:ok, Relay.Channels.Whatsapp.Message.kind()} | {:error, :window_closed | :no_content}
  def choose(open?, kinds) when is_boolean(open?) and is_list(kinds) do
    cond do
      open? and :free_form in kinds -> {:ok, :free_form}
      :template in kinds -> {:ok, :template}
      :free_form in kinds -> {:error, :window_closed}
      true -> {:error, :no_content}
    end
  end
end
