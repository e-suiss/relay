defmodule Relay.Migration.Displayed do
  @moduledoc """
  Client duplicate telemetry of a migration (OP-54, OP-80, OP-95). An SDK reports the digests of the notification identifiers it displayed; a digest the same subscriber already reported within x-relay-limits `displayed_notifications.duplicate_window` is a duplicate. The digests are remembered on Valkey only, as short-lived keys of the tenant: Valkey holds no record of truth, so a lost key costs at most an uncounted duplicate. Nothing about the notification's content is received or kept.

  Telemetry: `[:relay, :migration, :displayed]` with `count` and `duplicates`, exported as `relay_migration_displayed_total` and `relay_migration_displayed_duplicates_total`; the duplicate rate is their ratio.
  """

  alias Relay.Scope

  @window_ms Relay.Limits.seconds!(["displayed_notifications", "duplicate_window"]) * 1000

  # OP-54
  # OP-95
  @doc "Counts the displayed digests of a subscriber; returns how many were accepted and how many were duplicates."
  @spec record(Scope.t(), Relay.Id.t(), [String.t()]) ::
          {:ok, %{accepted: non_neg_integer(), duplicates: non_neg_integer()}}
          | {:error, Relay.Error.t()}
  def record(%Scope{} = scope, <<_::128>> = subscriber_id, digests) when is_list(digests) do
    subscriber = Relay.Id.to_string(subscriber_id)

    counted =
      Enum.reduce_while(digests, {:ok, 0}, fn digest, {:ok, duplicates} ->
        segments = ["displayed", subscriber, digest]

        case Relay.Platform.put_short_lived_new(scope, segments, "1", @window_ms) do
          {:ok, true} -> {:cont, {:ok, duplicates}}
          {:ok, false} -> {:cont, {:ok, duplicates + 1}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)

    with {:ok, duplicates} <- counted do
      :telemetry.execute(
        [:relay, :migration, :displayed],
        %{count: length(digests), duplicates: duplicates},
        %{}
      )

      {:ok, %{accepted: length(digests), duplicates: duplicates}}
    end
  end
end
