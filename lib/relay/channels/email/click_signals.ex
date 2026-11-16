defmodule Relay.Channels.Email.ClickSignals do
  @moduledoc """
  The human and bot classification of an e-mail click and the machine open flag of an e-mail open (CH-43, DS-30, DS-32, DS-52), on the content of the versioned `click_signals` data set. A click is `:likely_bot` when any signal holds and `:human` otherwise; the signal that decided is returned so it is kept on the event. The signals are tried in this order:

  | Signal | Holds when |
  |---|---|
  | `request_shape` | the request's method is one of `request.methods` (such as `HEAD`), or it lacks one of `request.required_headers` (a bodiless automation request) |
  | `scanner_ip:<operator>` | the client address is inside a published security scanner block of `ip_blocks` |
  | `user_agent` | the `User-Agent` contains one of the `user_agents` patterns, compared without case |
  | `timing` | the click comes less than `timing.after_send_ms` after the send or after the provider's delivery |
  | `burst` | with this click, at least `burst.distinct_links` distinct links of the same message were clicked within `burst.window_ms` |

  An open is a machine open when any of the same request signals holds or its `User-Agent` contains one of the `open_proxies` patterns (Apple Mail Privacy Protection, image proxies); an open is never decision input or delivery evidence either way.
  """

  @type request :: %{
          required(:method) => String.t(),
          required(:ip) => :inet.ip_address() | nil,
          required(:user_agent) => String.t() | nil,
          required(:headers) => [String.t()],
          required(:at_ms) => integer()
        }
  @type history :: %{
          required(:sent_ms) => integer() | nil,
          required(:delivered_ms) => integer() | nil,
          required(:clicks) => [{pos_integer(), integer()}]
        }
  @type class :: :human | :likely_bot

  # DS-30
  # DS-52
  @doc "Classifies a click of link number `link` with the message's `history`: its send and provider delivery times and its earlier clicks as `{link, at_ms}`. Returns the class and the deciding signal, `nil` for a human click."
  @spec classify(map(), request(), pos_integer(), history()) :: {class(), String.t() | nil}
  def classify(signals, request, link, history) do
    checks = [
      fn -> request_shape(signals, request) end,
      fn -> scanner_ip(signals, request) end,
      fn -> user_agent(signals["user_agents"], request, "user_agent") end,
      fn -> timing(signals, request, history) end,
      fn -> burst(signals, request, link, history) end
    ]

    case Enum.find_value(checks, & &1.()) do
      nil -> {:human, nil}
      signal -> {:likely_bot, signal}
    end
  end

  # DS-32
  @doc "Whether an open is a machine open, with the deciding signal."
  @spec machine_open(map(), request()) :: {boolean(), String.t() | nil}
  def machine_open(signals, request) do
    checks = [
      fn -> request_shape(signals, request) end,
      fn -> scanner_ip(signals, request) end,
      fn -> user_agent(signals["user_agents"], request, "user_agent") end,
      fn -> user_agent(signals["open_proxies"], request, "open_proxy") end
    ]

    case Enum.find_value(checks, & &1.()) do
      nil -> {false, nil}
      signal -> {true, signal}
    end
  end

  defp request_shape(signals, request) do
    shape = Map.get(signals, "request", %{})
    methods = Enum.map(Map.get(shape, "methods", []), &String.upcase/1)
    missing = Map.get(shape, "required_headers", []) -- request.headers

    if String.upcase(request.method) in methods or missing != [], do: "request_shape"
  end

  defp scanner_ip(_signals, %{ip: nil}), do: nil

  defp scanner_ip(signals, %{ip: ip}) do
    address = bits(normalize(ip))

    Enum.find_value(Map.get(signals, "ip_blocks", []), fn block ->
      if Enum.any?(Map.get(block, "cidrs", []), &inside?(address, &1)),
        do: "scanner_ip:" <> block["operator"]
    end)
  end

  defp user_agent(_patterns, %{user_agent: nil}, _signal), do: nil

  defp user_agent(patterns, %{user_agent: agent}, signal) do
    agent = String.downcase(agent)

    if Enum.any?(patterns || [], &String.contains?(agent, String.downcase(&1["pattern"]))),
      do: signal
  end

  defp timing(signals, request, history) do
    ms = get_in(signals, ["timing", "after_send_ms"])
    times = Enum.reject([history.sent_ms, history.delivered_ms], &is_nil/1)

    if is_integer(ms) and Enum.any?(times, &(request.at_ms >= &1 and request.at_ms - &1 < ms)),
      do: "timing"
  end

  defp burst(signals, request, link, history) do
    window = get_in(signals, ["burst", "window_ms"])
    distinct = get_in(signals, ["burst", "distinct_links"])
    ready? = is_integer(window) and is_integer(distinct)

    if ready? and distinct_links(history.clicks, request.at_ms, window, link) >= distinct,
      do: "burst"
  end

  defp distinct_links(clicks, at_ms, window, link) do
    recent = for {n, at} <- clicks, at_ms - at < window, do: n
    recent |> MapSet.new() |> MapSet.put(link) |> MapSet.size()
  end

  defp normalize({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: {div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)}

  defp normalize(ip), do: ip

  defp bits({a, b, c, d}), do: <<a, b, c, d>>

  defp bits({a, b, c, d, e, f, g, h}),
    do: <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>

  defp inside?(address, cidr) do
    with [text, size] <- String.split(cidr, "/"),
         {:ok, network} <- :inet.parse_strict_address(String.to_charlist(text)),
         {n, ""} <- Integer.parse(size),
         network = bits(network),
         true <- bit_size(network) == bit_size(address) and n <= bit_size(address) do
      <<prefix::bitstring-size(^n), _rest::bitstring>> = network
      <<own::bitstring-size(^n), _tail::bitstring>> = address
      own == prefix
    else
      _other -> false
    end
  end
end
