defmodule Relay.Repo.Migrations.SeedInstallation do
  use Ecto.Migration

  # TN-2
  # C-10
  def up do
    region = region!()

    execute("""
    DO $$
    DECLARE
      v_id uuid := uuidv7();
    BEGIN
      PERFORM set_config('relay.tenant_id', v_id::text, true);

      INSERT INTO relay.tenants (id, kind, access_tenant_id, region, sector, default_timezone,
        default_locale, status, status_changed_at, created_at, updated_at)
      VALUES (v_id, 'installation', 'installation', '#{region}', 'general', 'Etc/UTC', 'en',
        'active', now(), now(), now());

      INSERT INTO relay.installation (singleton, region, installation_tenant_id, created_at)
      VALUES (true, '#{region}', v_id, now());
    END
    $$
    """)

    # OP-13
    # OP-66
    execute(~S"""
    INSERT INTO relay.partition_policies (table_name, partition_interval, premake_horizon,
      alarm_threshold, hot_retention, updated_at, updated_by_ref)
    VALUES
      ('delivery_events', 'day', interval '14 days', interval '3 days', interval '90 days', now(), 'migration'),
      ('delivery_attempts', 'day', interval '14 days', interval '3 days', interval '90 days', now(), 'migration'),
      ('idempotency_keys', 'day', interval '14 days', interval '3 days', interval '90 days', now(), 'migration'),
      ('audit_log', 'month', interval '2 months', interval '3 days', interval '13 months', now(), 'migration'),
      ('outbox_events', 'month', interval '2 months', interval '3 days', interval '13 months', now(), 'migration'),
      ('usage_records', 'month', interval '2 months', interval '3 days', interval '13 months', now(), 'migration')
    """)
  end

  defp region! do
    case Relay.Region.cast(System.get_env("RELAY_REGION")) do
      {:ok, region} -> Relay.Region.dump(region)
      {:error, _} -> raise "RELAY_REGION must be set to the installation region: tr, eu or us"
    end
  end
end
