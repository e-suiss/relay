defmodule Relay.Release.Archive do
  @moduledoc """
  The cold archive release commands of the installation operator. They run on a running worker node through the release script `bin/archive` (`bin/archive restore --manifest <manifest id> --schema restore_…`), or directly as `bin/relay rpc 'Relay.Release.Archive.restore(manifest: "…", schema: "restore_…")'`.

  A restore loads one archived leaf into a new read-only `restore_…` schema after checking the archived object against its manifest; the live data is never touched. Results are `{:ok, map}` or `{:error, atom}`.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Platform.Maintenance], exports: []

  alias Relay.Platform.Maintenance.Restore

  @switches [manifest: :string, schema: :string]

  # OP-84
  @doc "Restores an archived leaf. Options: `manifest:` (the manifest id) and `schema:` (a new schema named `restore_…`)."
  @spec restore(keyword()) :: {:ok, map()} | {:error, atom()}
  def restore(opts) when is_list(opts) do
    with {:ok, id} <- manifest(opts[:manifest]),
         {:ok, schema} <- schema(opts[:schema]) do
      case Restore.run(id, schema) do
        {:ok, restored} -> {:ok, restored}
        {:error, %Relay.Error{code: code}} -> {:error, code}
      end
    end
  end

  # OP-84
  @doc "Runs the command that `bin/archive` names in `encoded`: its arguments, one per line, in base64. Prints the result and returns it."
  @spec run(String.t()) :: {:ok, map()} | {:error, atom()}
  def run(encoded) when is_binary(encoded) do
    result =
      with {:ok, text} <- decode(encoded),
           ["restore" | args] <- String.split(text, "\n", trim: true),
           {opts, [], []} <- OptionParser.parse(args, strict: @switches) do
        restore(opts)
      else
        {:error, _} = error -> error
        _other -> {:error, :invalid_arguments}
      end

    IO.puts(inspect(result, pretty: true))
    result
  end

  defp decode(encoded) do
    case Base.decode64(encoded) do
      {:ok, text} -> {:ok, text}
      :error -> {:error, :invalid_arguments}
    end
  end

  defp manifest(value) when is_binary(value) do
    case Relay.Id.parse(value) do
      {:ok, id} -> {:ok, id}
      {:error, _} -> {:error, :invalid_manifest}
    end
  end

  defp manifest(_value), do: {:error, :invalid_manifest}

  defp schema(value) when is_binary(value) do
    if Regex.match?(~r/^restore_[a-z0-9_]{1,54}$/, value),
      do: {:ok, value},
      else: {:error, :invalid_schema}
  end

  defp schema(_value), do: {:error, :invalid_schema}
end
