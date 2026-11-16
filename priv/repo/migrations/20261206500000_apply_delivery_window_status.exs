defmodule Relay.Repo.Migrations.ApplyDeliveryWindowStatus do
  use Ecto.Migration

  # DS-17
  # DS-18
  # INV-5
  def up do
    execute(~S"""
    CREATE OR REPLACE FUNCTION relay_private.delivery_status(p_delivery relay.deliveries)
      RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path = pg_catalog, pg_temp
    AS $fn$
      SELECT CASE
        WHEN p_delivery.failure_kind = 'skipped' THEN 'skipped'
        WHEN p_delivery.failure_kind = 'cancelled' THEN 'cancelled'
        WHEN p_delivery.failure_kind = 'expired' THEN 'expired'
        WHEN p_delivery.failure_kind IN ('failed', 'bounced') THEN 'failed'
        WHEN p_delivery.delivery_rank = 2 THEN 'delivered'
        WHEN p_delivery.delivery_rank = 1 AND p_delivery.window_stage = 2 THEN 'unknown'
        WHEN p_delivery.delivery_rank = 1 AND p_delivery.window_stage = 1 THEN 'unknown_pending'
        WHEN p_delivery.delivery_rank = 1 THEN 'sent'
        ELSE 'queued'
      END
    $fn$
    """)
  end

  def down, do: :ok
end
