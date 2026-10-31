defmodule RelayDev.Seed do
  @moduledoc """
  Sample data of the local environment (T-65 (1)): a sample tenant with its `live` and `test` environments and keys, a recipient in the test plane and the bundled data set versions, so the test plane is ready right after `just dev`. Running it again changes nothing.
  """

  @tenant "dev-sample-tenant"
  @recipient "dev-sample-recipient"

  # T-65 (1)
  @doc "Seeds the sample data and returns the external identifiers it wrote."
  @spec run() :: {:ok, map()} | {:error, term()}
  def run do
    {:ok, actor} = Relay.Actor.new(:system, "system:dev_seed", "system:dev_seed")

    with {:ok, _report} <- Relay.Datasets.load_package(actor),
         {:ok, tenant_id} <- tenant(actor),
         test = Relay.Scope.new!(tenant_id, :test),
         {:ok, {result, _id}} when result in [:created, :exists] <-
           Relay.Tenancy.create_recipient(test, %{
             id: Relay.Id.generate(),
             kind: :subscriber,
             external_id: @recipient
           }) do
      {:ok,
       %{
         tenant: Relay.ExternalId.encode("ten", tenant_id),
         environments: [:live, :test],
         recipient: @recipient
       }}
    end
  end

  defp tenant(actor) do
    attrs = %{
      id: Relay.Id.generate(),
      access_tenant_id: @tenant,
      region: installation_region(),
      sector: "general",
      default_timezone: "Europe/Istanbul",
      default_locale: "tr-TR",
      record_digest: :crypto.hash(:sha256, "dev-seed:" <> @tenant)
    }

    case Relay.Tenancy.Provisioning.create_tenant(attrs, actor) do
      {result, id} when result in [:created, :exists] and is_binary(id) -> {:ok, id}
      other -> {:error, other}
    end
  end

  defp installation_region do
    {:ok, %{rows: [[region]]}} =
      Relay.Repo.unscoped_query(:installation_lookup, "SELECT region FROM relay.installation", [])

    {:ok, region} = Relay.Region.cast(region)
    region
  end
end
