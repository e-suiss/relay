defmodule Relay.Access.LinkStore do
  @moduledoc """
  Data access of the Access link: the durable cache of the discovery documents and the key set (`relay.access_link`, one row). The row is written only through `relay_ops.access_link_store`, which also refuses a link to another region (INV-41) or another issuer; the network calls happen before, outside any transaction (INV-55).
  """

  alias Relay.Repo

  @read "SELECT issuer, state, discovery, authzen, jwks, access_region, management_api, event_subscriptions, fetched_at FROM relay.access_link"
  @results [:stored, :unchanged, :region_mismatch, :issuer_mismatch]

  @type row :: %{
          issuer: String.t(),
          state: String.t(),
          discovery: map() | nil,
          authzen: map() | nil,
          jwks: map() | nil,
          access_region: String.t() | nil,
          management_api: String.t() | nil,
          event_subscriptions: String.t() | nil,
          fetched_at: DateTime.t() | nil
        }

  # E-78
  # INV-41
  # INV-55
  @doc "Writes the result of a discovery fetch; documents that are `nil` mark a failed fetch."
  @spec store(map()) :: :stored | :unchanged | :region_mismatch | :issuer_mismatch
  def store(attrs) do
    [row] =
      Repo.call_unscoped!(:access_link, "relay_ops.access_link_store", [
        attrs.issuer,
        attrs.discovery,
        attrs.authzen,
        attrs.jwks,
        attrs.discovery_digest,
        attrs.jwks_digest,
        attrs.region,
        attrs.management_api,
        attrs.event_subscriptions
      ])

    Repo.code!(row["access_link_store"], @results)
  end

  # E-5
  # E-75
  @doc "Reads the cached link, `nil` before the first write."
  @spec read() :: row() | nil
  def read do
    case Repo.unscoped_query(:access_link, @read, []) do
      {:ok, %{rows: [values]}} -> row(values)
      {:ok, %{rows: []}} -> nil
      {:error, error} -> raise error
    end
  end

  defp row([issuer, state, discovery, authzen, jwks, region, management, events, fetched_at]) do
    %{
      issuer: issuer,
      state: state,
      discovery: discovery,
      authzen: authzen,
      jwks: jwks,
      access_region: region,
      management_api: management,
      event_subscriptions: events,
      fetched_at: fetched_at
    }
  end
end
