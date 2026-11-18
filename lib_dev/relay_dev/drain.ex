defmodule RelayDev.Drain do
  @moduledoc """
  The traffic side of the nightly deploy test (OP-87, T-5): it sends `POST /v1/events` of the sample test plane workflow at a constant rate to a running node while the node is stopped and started again, and records every event the node accepted; afterwards it checks that each accepted event went on to its notifications, so that no accepted request was lost between acceptance and the queue. Requests reach the node over plain HTTP from a trusted proxy address with `X-Forwarded-Proto: https`; each carries its own DPoP proof of the local Access stand-in.
  """

  @external "https://localhost"

  # OP-87
  @doc "Sends events for `seconds` at `rate` per second to `base` and writes the identifier of every accepted event to `out`, one per line; returns the counts by outcome."
  @spec traffic(String.t(), pos_integer(), pos_integer(), Path.t()) ::
          %{atom() => non_neg_integer()}
  def traffic(base, seconds, rate, out) do
    token = RelayDev.Seed.token()
    interval = div(1_000, rate)
    deadline = System.monotonic_time(:millisecond) + seconds * 1_000
    File.write!(out, "")
    send_loop(base, token, interval, deadline, out, %{accepted: 0, refused: 0, unreachable: 0})
  end

  # OP-87
  @doc "Checks within `timeout_s` that every event listed in `file` is readable and has its notifications; returns the identifiers that are not."
  @spec verify(String.t(), Path.t(), pos_integer()) :: [String.t()]
  def verify(base, file, timeout_s) do
    token = RelayDev.Seed.token()
    ids = file |> File.read!() |> String.split("\n", trim: true)
    deadline = System.monotonic_time(:millisecond) + timeout_s * 1_000
    pending(base, token, ids, deadline)
  end

  defp send_loop(base, token, interval, deadline, out, counts) do
    if System.monotonic_time(:millisecond) >= deadline do
      counts
    else
      started = System.monotonic_time(:millisecond)
      counts = Map.update!(counts, outcome(base, token, out), &(&1 + 1))
      Process.sleep(max(interval - (System.monotonic_time(:millisecond) - started), 0))
      send_loop(base, token, interval, deadline, out, counts)
    end
  end

  defp outcome(base, token, out) do
    path = "/v1/events"

    case request(base, token, :post, path, RelayDev.Seed.sample_event()) do
      {:ok, %{status: 202, body: %{"id" => id}}} ->
        File.write!(out, id <> "\n", [:append])
        :accepted

      {:ok, _response} ->
        :refused

      {:error, _reason} ->
        :unreachable
    end
  end

  defp pending(base, token, ids, deadline) do
    left = Enum.reject(ids, &notified?(base, token, &1))

    if left == [] or System.monotonic_time(:millisecond) >= deadline do
      left
    else
      Process.sleep(2_000)
      pending(base, token, left, deadline)
    end
  end

  defp notified?(base, token, id) do
    case request(base, token, :get, "/v1/events/" <> id, nil) do
      {:ok, %{status: 200, body: %{"notifications" => [_ | _]}}} -> true
      _other -> false
    end
  end

  defp request(base, token, method, path, body) do
    method_name = method |> Atom.to_string() |> String.upcase()
    proof = RelayDev.Access.proof(method_name, @external <> path, token)

    headers = [
      {"authorization", "DPoP " <> token},
      {"dpop", proof},
      {"x-forwarded-proto", "https"},
      {"x-forwarded-host", "localhost"},
      {"idempotency-key", Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}
    ]

    opts = [method: method, url: base <> path, headers: headers, retry: false]
    opts = opts ++ [receive_timeout: 15_000, connect_options: [timeout: 2_000]]
    opts = if body, do: Keyword.put(opts, :json, body), else: opts
    Req.request(opts)
  end
end
