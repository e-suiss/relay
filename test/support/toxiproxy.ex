defmodule RelayTest.Toxiproxy do
  @moduledoc """
  A small client of the Toxiproxy HTTP API (`TOXIPROXY_URL`, the `chaos` profile of `deploy/compose.yaml`) for the nightly chaos tests (T-52, OP-93). The proxies themselves are created by the nightly workflow before the suite starts, so the node's connections already run through them.
  """

  use Boundary, top_level?: true, deps: [], exports: []

  @doc "The Toxiproxy API base URL, or nil when the suite runs without Toxiproxy."
  @spec url() :: String.t() | nil
  def url, do: System.get_env("TOXIPROXY_URL")

  @doc "Enables or disables a proxy; a disabled proxy closes its connections and refuses new ones."
  @spec enabled(String.t(), boolean()) :: :ok
  def enabled(proxy, enabled?) do
    %{status: 200} = Req.post!(url() <> "/proxies/" <> proxy, json: %{enabled: enabled?})
    :ok
  end

  @doc "Adds a latency toxic of `ms` milliseconds to the downstream of a proxy."
  @spec latency(String.t(), String.t(), non_neg_integer()) :: :ok
  def latency(proxy, name, ms) do
    body = %{name: name, type: "latency", stream: "downstream", attributes: %{latency: ms}}
    %{status: 200} = Req.post!(url() <> "/proxies/" <> proxy <> "/toxics", json: body)
    :ok
  end

  @doc "Removes a toxic of a proxy; a missing toxic is not an error."
  @spec remove(String.t(), String.t()) :: :ok
  def remove(proxy, name) do
    _ = Req.delete!(url() <> "/proxies/" <> proxy <> "/toxics/" <> name, retry: false)
    :ok
  end
end
