defmodule Relay.Datasets.Package do
  @moduledoc """
  The data set versions Relay ships. Each data set is a directory `priv/datasets/<name>/` holding its JSON Schema 2020-12 document `schema.json` and its versions `v1.json`, `v2.json`, …; nothing else may be in the directory. A generated data set holds only its schema: `channel_event_evidence` has one version, composed from the adapter declarations under `priv/channels/` (`Relay.ChannelDeclarations.compose/1`, CH-71) and named by its content digest. Reading validates every version against the schema and computes the digests, before anything reaches the database.
  """

  alias Relay.Datasets.Schema

  @name ~r/\A[a-z][a-z0-9_]{2,63}\z/
  @version ~r/\Av([1-9][0-9]{0,8})\.json\z/
  @generated ["channel_event_evidence"]

  @type version :: %{
          no: pos_integer(),
          ref: String.t(),
          content: Schema.json(),
          digest: <<_::256>>
        }
  @type dataset :: %{
          name: String.t(),
          schema: map(),
          schema_digest: <<_::256>>,
          versions: [version(), ...]
        }

  @doc "Returns the directory of the bundled data sets."
  @spec root() :: Path.t()
  def root, do: Path.join(:code.priv_dir(:relay), "datasets")

  # OP-65 (5)
  @doc "Reads and validates every bundled data set under `root`, in name order with versions in number order."
  @spec read(Path.t()) :: {:ok, [dataset()]} | {:error, Relay.Error.t()}
  def read(root) do
    names =
      case File.ls(root) do
        {:ok, entries} -> entries |> Enum.filter(&File.dir?(Path.join(root, &1))) |> Enum.sort()
        {:error, :enoent} -> []
      end

    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case dataset(root, name) do
        {:ok, dataset} -> {:cont, {:ok, [dataset | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> then(fn
      {:ok, datasets} -> {:ok, Enum.reverse(datasets)}
      error -> error
    end)
  end

  defp dataset(root, name) do
    dir = Path.join(root, name)

    with :ok <- check(Regex.match?(@name, name), name, "not a data set name"),
         {:ok, files} <- File.ls(dir),
         {:ok, sources} <- sources(root, name, files -- ["schema.json"]),
         :ok <- check("schema.json" in files, name, "schema.json is missing"),
         {:ok, schema} <- json(dir, name, "schema.json"),
         {:ok, built} <- with_name(Schema.build(schema), name),
         {:ok, schema_digest} <- with_name(Schema.digest(schema), name),
         {:ok, versions} <- versions(name, built, sources) do
      {:ok, %{name: name, schema: schema, schema_digest: schema_digest, versions: versions}}
    end
  end

  # CH-71
  defp sources(root, name, []) when name in @generated do
    channels = Path.join(Path.dirname(root), "channels")

    case Relay.ChannelDeclarations.compose(channels) do
      {:ok, content} -> {:ok, [{1, nil, content}]}
      {:error, error} -> {:error, error}
    end
  end

  defp sources(_root, name, files) when name in @generated,
    do: error(name, "unexpected file #{hd(files)}")

  defp sources(root, name, files) do
    with {:ok, numbers} <- version_numbers(name, files) do
      Enum.reduce_while(numbers, {:ok, []}, fn no, {:ok, acc} ->
        case json(Path.join(root, name), name, "v#{no}.json") do
          {:ok, content} -> {:cont, {:ok, [{no, "v#{no}", content} | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> then(fn
        {:ok, sources} -> {:ok, Enum.reverse(sources)}
        error -> error
      end)
    end
  end

  defp version_numbers(name, files) do
    numbers =
      for file <- files do
        case Regex.run(@version, file) do
          [_, n] -> String.to_integer(n)
          nil -> {:unexpected, file}
        end
      end

    case Enum.find(numbers, &match?({:unexpected, _}, &1)) do
      nil when numbers != [] -> {:ok, Enum.sort(numbers)}
      nil -> error(name, "the data set has no version")
      {:unexpected, file} -> error(name, "unexpected file #{file}")
    end
  end

  defp versions(name, root, sources) do
    Enum.reduce_while(sources, {:ok, []}, fn {no, ref, content}, {:ok, acc} ->
      with :ok <- with_name(Schema.validate(root, content), name),
           :ok <- with_name(Relay.Datasets.consistent(name, content), name),
           {:ok, digest} <- with_name(Schema.digest(content), name) do
        version = %{no: no, ref: ref || digest_ref(digest), content: content, digest: digest}
        {:cont, {:ok, [version | acc]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> then(fn
      {:ok, versions} -> {:ok, Enum.reverse(versions)}
      error -> error
    end)
  end

  defp digest_ref(digest),
    do: "sha256:" <> binary_part(Base.encode16(digest, case: :lower), 0, 16)

  # sobelow_skip ["Traversal.FileModule"]
  defp json(dir, name, file) do
    with {:ok, text} <- File.read(Path.join(dir, file)),
         {:ok, value} <- Jason.decode(text) do
      {:ok, value}
    else
      _ -> error(name, "#{file} is not readable JSON")
    end
  end

  defp with_name({:error, %Relay.Error{} = error}, name),
    do: {:error, %{error | details: Map.put(error.details, :dataset, name)}}

  defp with_name(result, _name), do: result

  defp check(true, _name, _message), do: :ok
  defp check(false, name, message), do: error(name, message)

  defp error(name, message),
    do: {:error, Relay.Error.new(:invalid_package, message, %{dataset: name})}
end
