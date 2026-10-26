defmodule RelayDev.Release do
  @moduledoc """
  Release gates: checks the release workflow runs on a version tag and normal CI does not, because what they refuse may stay open on `main` until a release. The active `retention_periods` version of a release is its newest bundled version, which the release activates (OP-65); a row of it whose legal basis still awaits legal approval stops the release.
  """

  alias RelayDev.Lint.Violation

  @retention_periods "priv/datasets/retention_periods"
  @version ~r/\Av([1-9][0-9]{0,8})\.json\z/
  @pending_legal_approval "pending legal approval"

  # OP-72 (1)
  # F-33
  @doc "The marker of a legal basis that awaits legal approval: a `legal_basis` is either exactly this marker or the marker followed by a reference in parentheses, as in `pending legal approval (OP-71.7)`."
  @spec pending_legal_approval() :: String.t()
  def pending_legal_approval, do: @pending_legal_approval

  # OP-72 (1)
  @doc "Returns true if a legal basis awaits legal approval (`pending_legal_approval/0`)."
  @spec pending_legal_approval?(term()) :: boolean()
  def pending_legal_approval?(@pending_legal_approval), do: true

  def pending_legal_approval?(@pending_legal_approval <> " (" <> reference),
    do: String.ends_with?(reference, ")") and byte_size(reference) > 1

  def pending_legal_approval?(_legal_basis), do: false

  # OP-72 (1)
  # F-33
  @doc "Returns the open release gates under `root`: each row of the newest bundled `retention_periods` version whose legal basis awaits legal approval, or the absence of a readable version."
  @spec gate(Path.t()) :: [Violation.t()]
  def gate(root) do
    case newest_version(Path.join(root, @retention_periods)) do
      {:ok, file} -> pending_rows(root, Path.join(@retention_periods, file))
      :error -> [violation(@retention_periods, "no retention_periods version is bundled")]
    end
  end

  defp newest_version(dir) do
    versions =
      case File.ls(dir) do
        {:ok, files} ->
          for file <- files, [_, no] <- [Regex.run(@version, file)] do
            {String.to_integer(no), file}
          end

        {:error, _reason} ->
          []
      end

    case Enum.max_by(versions, &elem(&1, 0), fn -> nil end) do
      {_no, file} -> {:ok, file}
      nil -> :error
    end
  end

  defp pending_rows(root, path) do
    with {:ok, text} <- File.read(Path.join(root, path)),
         {:ok, %{"periods" => periods}} when is_list(periods) <- Jason.decode(text) do
      for %{"legal_basis" => basis} = row <- periods, message = open_basis(basis) do
        violation(
          path,
          "#{row["region"]}/#{row["sector"]}/#{row["retention_class"]}: legal basis #{inspect(basis)} #{message}"
        )
      end
    else
      _other -> [violation(path, "not a readable retention_periods version")]
    end
  end

  defp open_basis(basis) do
    cond do
      pending_legal_approval?(basis) ->
        "awaits legal approval"

      is_binary(basis) and String.contains?(String.downcase(basis), "pending") ->
        "mentions pending approval without the marker #{inspect(@pending_legal_approval)}"

      true ->
        nil
    end
  end

  defp violation(path, message),
    do: %Violation{path: path, line: 0, rule: "legal_approval", message: message}
end
