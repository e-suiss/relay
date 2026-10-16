defmodule Relay.Audit.Checkpointer.Store do
  @moduledoc false

  alias Relay.Repo

  @spec pending(String.t(), pos_integer()) ::
          {:ok, [map()], String.t() | nil} | {:error, Relay.Error.t()}
  def pending(watermark, limit) do
    """
    SELECT tenant_id, environment, audit_id, created_at, txid::text, record_digest, upper_xmin::text
    FROM relay_ops.audit_pending($1::text::xid8, $2)
    """
    |> Repo.query([watermark, limit])
    |> case do
      {:ok, %{rows: rows}} ->
        upper = Enum.find_value(rows, fn row -> List.last(row) end)
        {:ok, Enum.map(rows, &row/1), upper}

      {:error, _} ->
        {:error, Relay.Error.new(:database_error, "audit watermark query failed")}
    end
  end

  defp row([tenant, environment, id, created_at, txid, digest, _upper]) do
    %{
      tenant_id: tenant,
      environment: environment,
      audit_id: id,
      created_at: created_at,
      txid: String.to_integer(txid),
      record_digest: digest
    }
  end
end
