defmodule Relay.Delivery.Projection do
  @moduledoc """
  The external projection of a delivery, derived from its internal axes (DS-14, DS-17). It is the same rule as the database's `relay_private.delivery_status`, which the query surface reads:

    1. `skipped`, `expired` and `cancelled` are definite terminals: nothing was sent.
    2. A valid definite failure is `failed`; a failure after delivery is only kept when the channel's table says it is valid (DS-6), and `delivered_at` stays.
    3. Otherwise the delivery axis decides: `delivered` once any attempt's evidence delivered it (DS-5), `sent` while the provider only accepted it.
    4. Without a definite event the window rule applies to `sent`: `unknown_pending` after the short window, `unknown` after the long one (DS-18). A late definite event always lifts them (DS-20).
    5. Everything else waits: `queued`.

  A notification has no delivery status of its own: its view is its deliveries and the number of deliveries per status (DS-9); the run state of its workflow is a separate field.
  """

  @statuses ~w(queued sent delivered unknown_pending unknown failed skipped expired cancelled)

  @type status :: String.t()

  # DS-14
  @doc "The nine external statuses, in contract order."
  @spec statuses() :: [status(), ...]
  def statuses, do: @statuses

  # DS-17
  # DS-18
  @doc "The external status of a delivery from its projection columns (`failure_kind`, `delivery_rank`, `window_stage`)."
  @spec status(map()) :: status()
  def status(%{} = delivery) do
    case {delivery["failure_kind"], delivery["delivery_rank"], delivery["window_stage"] || 0} do
      {kind, _rank, _stage} when kind in ["skipped", "expired", "cancelled"] -> kind
      {kind, _rank, _stage} when kind in ["failed", "bounced"] -> "failed"
      {_kind, 2, _stage} -> "delivered"
      {_kind, 1, 2} -> "unknown"
      {_kind, 1, 1} -> "unknown_pending"
      {_kind, 1, _stage} -> "sent"
      _other -> "queued"
    end
  end

  # DS-9
  @doc "The number of deliveries per external status; a status without a delivery is absent."
  @spec counts([map()]) :: %{optional(status()) => pos_integer()}
  def counts(deliveries) when is_list(deliveries), do: Enum.frequencies_by(deliveries, &status/1)

  # DS-3
  # DS-14
  @doc "The engagement of a delivery from its projection columns: a timestamp per kind and, for a click, whether a human or a likely bot clicked (`human` or `bot`)."
  @spec engagement(map()) :: %{String.t() => term()}
  def engagement(%{} = delivery) do
    %{
      "seen_at" => delivery["seen_at"],
      "read_at" => delivery["read_at"],
      "clicked_at" => delivery["clicked_at"],
      "clicked_by" => clicked_by(delivery["clicked_by"]),
      "archived_at" => delivery["archived_at"]
    }
  end

  defp clicked_by("human"), do: "human"
  defp clicked_by("likely_bot"), do: "bot"
  defp clicked_by(_none), do: nil
end
