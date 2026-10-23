defmodule Relay.Datasets.Version do
  @moduledoc """
  One immutable version of a data set in one scope. A decision made from a version records its reference (`ref/1`), so the decision can be reproduced later from the same version.
  """

  @enforce_keys [
    :scope,
    :id,
    :dataset_name,
    :version_no,
    :content,
    :content_digest,
    :source,
    :source_ref,
    :valid_from
  ]
  defstruct @enforce_keys

  @type level :: :installation | :tenant
  @type t :: %__MODULE__{
          scope: Relay.Scope.t(),
          id: Relay.Id.t(),
          dataset_name: String.t(),
          version_no: pos_integer(),
          content: term(),
          content_digest: <<_::256>>,
          source: :package | :operator,
          source_ref: String.t(),
          valid_from: DateTime.t()
        }

  @type ref :: %{String.t() => String.t() | pos_integer()}

  @doc "Builds a version from a `dataset_versions` row."
  @spec from_row(map()) :: t()
  def from_row(row) do
    %__MODULE__{
      scope: Relay.Scope.new!(row["tenant_id"], row["environment"]),
      id: row["id"],
      dataset_name: row["dataset_name"],
      version_no: row["version_no"],
      content: row["content"],
      content_digest: row["content_digest"],
      source: source(row["source"]),
      source_ref: row["source_ref"],
      valid_from: row["valid_from"]
    }
  end

  defp source("package"), do: :package
  defp source("operator"), do: :operator

  # OP-65 (4)
  @doc "Returns the reference a decision records: the data set, the version's external id and number, and whether it is the installation's or the tenant's version."
  @spec ref(t(), Relay.Id.t()) :: ref()
  def ref(%__MODULE__{} = version, installation_tenant_id) do
    %{
      "dataset" => version.dataset_name,
      "version_id" => Relay.ExternalId.encode("dsv", version.id),
      "version_no" => version.version_no,
      "level" => Atom.to_string(level(version, installation_tenant_id))
    }
  end

  @doc "Returns whether a version belongs to the installation or to a tenant."
  @spec level(t(), Relay.Id.t()) :: level()
  def level(%__MODULE__{scope: scope}, installation_tenant_id),
    do: if(scope.tenant_id == installation_tenant_id, do: :installation, else: :tenant)
end
