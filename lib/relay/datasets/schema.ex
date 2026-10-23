defmodule Relay.Datasets.Schema do
  @moduledoc """
  JSON Schema 2020-12 validation of data set content, and the content digest. A schema that names another dialect in `$schema` is refused; references resolve only within the schema and the bundled meta-schemas, never over the network. The digest of a schema or of content is SHA-256 over its deterministic CBOR encoding (`Relay.Canonical`), so content with floats, which has no canonical encoding, is refused.
  """

  @dialect "https://json-schema.org/draft/2020-12/schema"

  @type json ::
          nil | boolean() | integer() | float() | String.t() | [json()] | %{String.t() => json()}
  @type t :: JSV.Root.t()

  @doc "Returns the only accepted `$schema` dialect."
  @spec dialect() :: String.t()
  def dialect, do: @dialect

  # OP-65 (1)
  @doc "Builds a validator from a JSON Schema 2020-12 document."
  @spec build(term()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def build(%{} = schema) do
    with :ok <- dialect(schema),
         {:ok, root} <- JSV.build(schema, default_meta: @dialect) do
      {:ok, root}
    else
      {:error, %Relay.Error{} = error} -> {:error, error}
      {:error, _exception} -> invalid_schema()
    end
  end

  def build(_schema), do: invalid_schema()

  defp dialect(%{"$schema" => @dialect}), do: :ok
  defp dialect(%{"$schema" => _other}), do: invalid_schema()
  defp dialect(%{}), do: :ok

  # OP-65 (1)
  @doc "Validates content against a built schema; the content is never cast."
  @spec validate(t(), json()) :: :ok | {:error, Relay.Error.t()}
  def validate(%JSV.Root{} = root, content) do
    case JSV.validate(content, root, cast: false) do
      {:ok, _content} ->
        :ok

      {:error, error} ->
        {:error,
         Relay.Error.new(:invalid_content, "content does not match the data set schema", %{
           errors: error |> JSV.normalize_error() |> error_count()
         })}
    end
  end

  defp error_count(%{details: details}) when is_list(details), do: length(details)
  defp error_count(_normalized), do: 1

  # OP-65 (2)
  # TN-65 (3)
  @doc "Computes the SHA-256 digest of the deterministic CBOR encoding of a JSON value."
  @spec digest(json()) :: {:ok, <<_::256>>} | {:error, Relay.Error.t()}
  def digest(value) do
    with {:ok, encoded} <- Relay.Canonical.encode(value),
         do: {:ok, :crypto.hash(:sha256, encoded)}
  end

  defp invalid_schema,
    do: {:error, Relay.Error.new(:invalid_schema, "not a JSON Schema 2020-12 document")}
end
