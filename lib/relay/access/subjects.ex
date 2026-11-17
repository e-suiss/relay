defmodule Relay.Access.Subjects do
  @moduledoc """
  The identity of an agent between Access and Relay (E-106, AG-75, MD-10). Access tokens carry a pairwise `sub` that names no Party, while Access events name the Party; Relay maps one to the other with Access's subject resolution (`POST /access/v1/tenants/{tenant}/subjects:resolve`, Access OP-149 A11), whose address template is `endpoints.subject_resolution` of the linked issuer's Suiss configuration. A Party belongs to one Access environment of its tenant, so the environments the tenant snapshot names are asked in turn until one resolves it; Relay asks as its own client, so the `sub` is the one in Relay's sector.

  Every call runs outside any transaction. An answer that resolves nothing, a lookup Access does not take and a tenant Access does not know are `:unknown`; an Access that cannot answer is `service_unavailable`. The template is kept for five minutes in `Relay.Access.Cache`.
  """

  alias Relay.Access.Cache
  alias Relay.Access.Client
  alias Relay.Access.Discovery
  alias Relay.Access.Http
  alias Relay.Access.Realms

  @template_ms 300_000
  @tenant ~r/\A[A-Za-z0-9_-]{1,128}\z/

  @type answer :: {:ok, String.t()} | :unknown | {:error, Relay.Error.t()}

  # E-106
  # AG-75
  @doc "The pairwise `sub` in Relay's sector of an Access Party of `access_tenant`."
  @spec sub(String.t(), String.t()) :: answer()
  def sub(access_tenant, party) when is_binary(party),
    do: resolve(access_tenant, {:parties, party}, {"party", "sub"})

  # E-106
  # AG-75
  @doc "The Access Party of `access_tenant` whose pairwise `sub` in Relay's sector is `sub`."
  @spec party(String.t(), String.t()) :: answer()
  def party(access_tenant, sub) when is_binary(sub),
    do: resolve(access_tenant, {:subs, sub}, {"sub", "party"})

  defp resolve(tenant, {kind, value}, names) do
    with {:ok, tenant} <- tenant(tenant),
         {:ok, template} <- template(),
         {:ok, environments} <- environments(tenant) do
      url = String.replace(template, "{tenant}", URI.encode(tenant, &URI.char_unreserved?/1))

      Enum.reduce_while(environments, :unknown, fn environment, :unknown ->
        url
        |> Client.resolve_subjects(environment, {kind, [value]})
        |> step(value, names)
      end)
    end
  end

  defp step({:ok, %{resolved: pairs}}, value, {from, to}) do
    case Enum.find_value(pairs, &counterpart(&1, from, value, to)) do
      nil -> {:cont, :unknown}
      found -> {:halt, {:ok, found}}
    end
  end

  defp step({:error, :refused}, _value, _names), do: {:cont, :unknown}
  defp step({:error, :not_found}, _value, _names), do: {:halt, :unknown}
  defp step({:error, _error}, _value, _names), do: {:halt, unavailable()}

  defp counterpart(pair, from, value, to) do
    found = pair[to]
    if pair[from] == value and is_binary(found) and found != "", do: found
  end

  defp tenant(tenant) when is_binary(tenant) do
    if Regex.match?(@tenant, tenant), do: {:ok, tenant}, else: unavailable()
  end

  defp tenant(_tenant), do: unavailable()

  defp environments(tenant) do
    case Realms.snapshot(tenant) do
      {:ok, %{"tenant" => ^tenant} = snapshot} ->
        {:ok, ids(Map.get(snapshot, "environments", snapshot["realms"]))}

      {:ok, _other} ->
        {:ok, []}

      {:error, :not_found} ->
        {:ok, []}

      {:error, _error} ->
        unavailable()
    end
  end

  defp ids(environments) when is_list(environments) do
    for %{"id" => id} <- environments, is_binary(id), do: id
  end

  defp ids(_environments), do: []

  defp template do
    case Cache.fetch(:subject_resolution) do
      {:ok, template} -> {:ok, template}
      :miss -> read_template()
    end
  end

  defp read_template do
    with issuer when is_binary(issuer) <- Relay.Access.issuer(),
         {:ok, document, _raw} <- Http.get_json(Discovery.suiss_url(issuer)),
         {:ok, %{subject_resolution: template}} when is_binary(template) <-
           Discovery.parse_suiss(document, issuer) do
      :ok = Cache.put(:subject_resolution, template, @template_ms)
      {:ok, template}
    else
      _unusable -> unavailable()
    end
  end

  defp unavailable,
    do: {:error, Relay.Error.new(:service_unavailable, "Access cannot resolve the subject now")}
end
