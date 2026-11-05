defmodule Relay.Channels.Email.Dmarc do
  @moduledoc """
  DMARC (DMARCbis, RFC 9989) policy discovery and organizational domain by the DNS tree walk, without a public suffix list (CH-36). The walk queries `_dmarc.<name>` for the author domain and then for its parents: from a name of eight or more labels it continues at the last seven, otherwise it drops the leftmost label, down to the top-level label. The policy record is the first valid one found. The organizational domain is the name of the first record with `psd=n`, the name one label below the first record with `psd=y`, otherwise the name with the fewest labels that has a record, otherwise the author domain.

  A valid record starts with `v=DMARC1`; a name with more than one valid record has none.
  """

  @type tags :: %{String.t() => String.t()}
  @type policy :: %{
          name: String.t(),
          record: tags(),
          policy: String.t() | nil,
          org_domain: String.t()
        }

  # CH-36
  @doc "The names the tree walk queries for `domain`, `_dmarc.` prefix not included, in order."
  @spec targets(String.t()) :: [String.t()]
  def targets(domain) do
    labels = domain |> String.trim_trailing(".") |> String.downcase(:ascii) |> String.split(".")
    labels |> walk([]) |> Enum.reverse() |> Enum.map(&Enum.join(&1, "."))
  end

  defp walk([_only] = labels, acc), do: [labels | acc]

  defp walk(labels, acc) when length(labels) >= 8,
    do: walk(Enum.take(labels, -7), [labels | acc])

  defp walk([_first | rest] = labels, acc), do: walk(rest, [labels | acc])

  # CH-36
  @doc "Discovers the DMARC policy of `domain`: the record found, the policy that applies to the domain itself (`sp` when the record belongs to a parent and names one) and the organizational domain; `nil` when no record is found."
  @spec discover(String.t(), module()) :: policy() | nil
  def discover(domain, resolver) do
    domain = domain |> String.trim_trailing(".") |> String.downcase(:ascii)

    found =
      Enum.flat_map(targets(domain), fn name ->
        case record(name, resolver) do
          nil -> []
          record -> [{name, record}]
        end
      end)

    case found do
      [] ->
        nil

      [{name, record} | _rest] ->
        %{
          name: name,
          record: record,
          policy: applied(domain, name, record),
          org_domain: org(domain, found)
        }
    end
  end

  # CH-36
  @doc "The organizational domain of `domain` by the tree walk."
  @spec org_domain(String.t(), module()) :: String.t()
  def org_domain(domain, resolver) do
    case discover(domain, resolver) do
      nil -> domain |> String.trim_trailing(".") |> String.downcase(:ascii)
      %{org_domain: org} -> org
    end
  end

  # CH-36
  @doc "Whether two domains are aligned: equal under `s`, or of the same organizational domain under `r`."
  @spec aligned?(String.t(), String.t(), String.t(), module()) :: boolean()
  def aligned?(a, b, "s", _resolver), do: String.downcase(a, :ascii) == String.downcase(b, :ascii)
  def aligned?(a, b, _relaxed, resolver), do: org_domain(a, resolver) == org_domain(b, resolver)

  defp applied(domain, domain, record), do: record["p"]
  defp applied(_domain, _name, record), do: record["sp"] || record["p"]

  defp org(domain, found) do
    labels = label_count(domain)

    marked =
      Enum.find_value(found, fn {name, record} ->
        case record["psd"] do
          "n" -> name
          "y" -> below(domain, name, labels)
          _other -> nil
        end
      end)

    marked || found |> Enum.min_by(&label_count(elem(&1, 0))) |> elem(0)
  end

  defp below(domain, name, labels) do
    count = label_count(name) + 1

    if count <= labels,
      do: domain |> String.split(".") |> Enum.take(-count) |> Enum.join("."),
      else: domain
  end

  defp label_count(name), do: name |> String.split(".") |> length()

  defp record(name, resolver) do
    case resolver.txt("_dmarc." <> name) do
      {:ok, records} ->
        case records |> Enum.map(&Enum.join/1) |> Enum.filter(&dmarc?/1) do
          [record] -> parse(record)
          _none_or_many -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  @doc "Whether a TXT record, its strings joined, is a DMARC record."
  @spec dmarc?(String.t()) :: boolean()
  def dmarc?(record) do
    case record |> String.split(";", parts: 2) |> hd() |> String.replace(" ", "") do
      "v=" <> version -> String.upcase(version, :ascii) == "DMARC1"
      _other -> false
    end
  end

  @doc "The tags of a DMARC record, keys and the policy values lowercased."
  @spec parse(String.t()) :: tags()
  def parse(record) do
    record
    |> String.split(";")
    |> Enum.flat_map(fn tag ->
      case :binary.split(tag, "=") do
        [key, value] -> [{key |> String.trim() |> String.downcase(:ascii), String.trim(value)}]
        [_bare] -> []
      end
    end)
    |> Map.new(fn
      {key, value} when key in ["p", "sp", "np", "adkim", "aspf", "t", "psd"] ->
        {key, String.downcase(value, :ascii)}

      pair ->
        pair
    end)
  end

  # CH-36
  @doc """
  The findings of a discovered policy: `dmarc_missing` (error) when there is none; `dmarc_legacy_tags` when the record still uses `pct`, `rf` or `ri`; `dmarc_testing` when `t=y`; and the suggestions `dmarc_ramp_with_testing` (at `p=none`, move on with `t=y`), `dmarc_np_reject` and `dmarc_strict_alignment`.
  """
  @spec findings(policy() | nil) :: [{:error | :warning | :suggestion, atom()}]
  def findings(nil), do: [{:error, :dmarc_missing}]

  def findings(%{record: record, policy: policy}) do
    [
      {Enum.any?(["pct", "rf", "ri"], &Map.has_key?(record, &1)), {:warning, :dmarc_legacy_tags}},
      {record["t"] == "y", {:warning, :dmarc_testing}},
      {policy in [nil, "none"], {:suggestion, :dmarc_ramp_with_testing}},
      {record["np"] != "reject", {:suggestion, :dmarc_np_reject}},
      {record["adkim"] != "s" or record["aspf"] != "s", {:suggestion, :dmarc_strict_alignment}}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end
end
