defmodule Relay.Delivery.Projection do
  @moduledoc """
  The engagement part of the external projection of a delivery (DS-14), read from the engagement axis of its projection (DS-3). The external status itself is derived in the database from the delivery, failure and window axes, by the one function the query surface reads.
  """

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
