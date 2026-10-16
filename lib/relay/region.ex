defmodule Relay.Region do
  @moduledoc """
  SaaS regions: `tr`, `eu` and `us`. A tenant chooses its region once; the region never changes.
  """

  @type t :: :tr | :eu | :us

  # C-10
  # TN-2
  # TN-55
  @doc "Returns every region."
  @spec all() :: [t(), ...]
  def all, do: [:tr, :eu, :us]

  @doc "Casts a region from its atom or its text form."
  @spec cast(term()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def cast(region) when region in [:tr, :eu, :us], do: {:ok, region}
  def cast("tr"), do: {:ok, :tr}
  def cast("eu"), do: {:ok, :eu}
  def cast("us"), do: {:ok, :us}
  def cast(_other), do: {:error, Relay.Error.new(:invalid_region, "not a region")}

  @doc "Returns the text form of a region."
  @spec dump(t()) :: String.t()
  def dump(region) when region in [:tr, :eu, :us], do: Atom.to_string(region)
end
