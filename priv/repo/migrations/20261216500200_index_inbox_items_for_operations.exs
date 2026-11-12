defmodule Relay.Repo.Migrations.IndexInboxItemsForOperations do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @partitions 16
  @indexes [
    {"updated_index", "(tenant_id, environment, updated_at)", ""},
    {"retention_index", "(tenant_id, environment, last_activity_at)", " WHERE retired_at IS NULL"}
  ]

  # IN-18
  # OP-42
  # IN-44
  # OP-14
  # OP-57 (3)
  def up do
    for {name, columns, where} <- @indexes do
      execute(
        "CREATE INDEX IF NOT EXISTS inbox_items_#{name} ON ONLY relay.inbox_items #{columns}#{where}"
      )

      for remainder <- 0..(@partitions - 1) do
        partition = "inbox_items_p" <> String.pad_leading(Integer.to_string(remainder), 6, "0")

        execute(
          "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{partition}_#{name} ON relay.#{partition} #{columns}#{where}"
        )

        execute(
          "ALTER INDEX relay.inbox_items_#{name} ATTACH PARTITION relay.#{partition}_#{name}"
        )
      end
    end
  end

  def down, do: :ok
end
