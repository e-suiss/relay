defmodule Relay.Repo.Migrations.AddCategoryDensity do
  use Ecto.Migration

  # WF-30
  # PC-50
  # PC-58 (6)
  # OP-57
  def up do
    execute("ALTER TABLE relay.categories ADD COLUMN density jsonb")

    execute(~S"""
    ALTER TABLE relay.categories ADD CONSTRAINT categories_density_check
      CHECK (density IS NULL OR (pg_column_size(density) <= 1024
        AND jsonb_typeof(density) = 'object'
        AND COALESCE(jsonb_typeof(density -> 'limit'), '') = 'number'
        AND COALESCE(jsonb_typeof(density -> 'window'), '') = 'string'
        AND COALESCE(density ->> 'per', '') IN ('recipient', 'device'))) NOT VALID
    """)

    execute("ALTER TABLE relay.digest_windows DROP CONSTRAINT digest_windows_origin_check")

    execute(~S"""
    ALTER TABLE relay.digest_windows ADD CONSTRAINT digest_windows_origin_check
      CHECK (origin IN ('step', 'density', 'quiet_hours', 'frequency')) NOT VALID
    """)
  end

  def down, do: :ok
end
