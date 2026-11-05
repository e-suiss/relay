defmodule Relay.Channels.Simulated do
  @moduledoc """
  The simulated result table of the fake provider (CH-72, X-26, DS-23), the single source of the table: the fake adapter, `GET /v1/test/simulated-results` and the documentation are all built from `table/0`.

  The result comes from the address only, and the addresses live in ranges set aside for tests:

    * email: `<result>@sim.relay.test` (`.test` is reserved by RFC 2606);
    * phone: `+9905550000NN`, in the `+99x` prefix the ITU has not assigned, where `NN` is the result's two-digit code, `01` to `15` in the order of the list;
    * push and Web Push tokens, WhatsApp and messaging targets: `sim:<result>`.

  Every other address is `delivered`. On the live plane these ranges are refused as `invalid_recipient` (`reserved?/2`); the fake adapter runs only on the test plane and in `shadow` mode.
  """

  alias Relay.Channels.Adapter

  @results [
    {"delivered", "Delivered; the default for every address outside the table."},
    {"sent_only", "Accepted by the provider; no delivery information follows."},
    {"delayed_delivery", "Accepted; delivered after five minutes of virtual time."},
    {"hard_bounce", "A hard bounce: a permanent target failure."},
    {"soft_bounce", "A soft bounce: a transient failure."},
    {"complaint", "Delivered, then a complaint."},
    {"not_delivered", "Accepted, then reported not delivered."},
    {"unregistered", "The token is no longer registered (APNs 410, FCM UNREGISTERED)."},
    {"rate_limited", "Rate limited: 429 with Retry-After 30."},
    {"transient_error", "A transient provider error."},
    {"timeout", "No answer: the uncertain outcome path."},
    {"auth_error", "The provider refused the credentials."},
    {"sender_config_error", "The sender identity is not configured at the provider."},
    {"content_rejected", "The provider refused the content."},
    {"unknown_code", "A provider code without a mapping: classified unknown with an alarm."}
  ]

  @names Enum.map(@results, &elem(&1, 0))
  @domain "sim.relay.test"
  @phone ~r/\A\+9905550000(\d\d)\z/
  @delayed_ms 5 * 60_000
  @retry_after_ms 30_000

  @type kind :: :email | :phone | :token
  @type result :: String.t()

  # CH-72
  # X-26
  @doc "The result names in table order."
  @spec results() :: [result(), ...]
  def results, do: @names

  # CH-72
  # X-26
  @doc "The table: per result its email address, phone number, token or target, and description."
  @spec table() :: [%{required(String.t()) => String.t()}, ...]
  def table do
    for {{name, description}, n} <- Enum.with_index(@results, 1) do
      %{
        "result" => name,
        "email" => name <> "@" <> @domain,
        "phone" => "+9905550000" <> String.pad_leading(Integer.to_string(n), 2, "0"),
        "token" => "sim:" <> name,
        "description" => description
      }
    end
  end

  # CH-72
  @doc "The kind of target a channel's address is: an email address, a phone number, or a token or target."
  @spec kind(String.t()) :: kind()
  def kind("email"), do: :email
  def kind(channel) when channel in ["sms", "voice"], do: :phone
  def kind(_channel), do: :token

  # CH-72
  @doc "The simulated result of an address; every address outside the table is `delivered`."
  @spec result(kind(), String.t()) :: result()
  def result(:email, address) do
    case String.split(String.downcase(address), "@", parts: 2) do
      [local, @domain] when local in @names -> local
      _other -> "delivered"
    end
  end

  def result(:phone, number) do
    with [_, code] <- Regex.run(@phone, number),
         n when n in 1..15 <- String.to_integer(code) do
      Enum.at(@names, n - 1)
    else
      _other -> "delivered"
    end
  end

  def result(:token, "sim:" <> name) when name in @names, do: name
  def result(:token, _token), do: "delivered"

  # CH-72
  # X-25
  @doc "Returns true when an address lies in a simulated range: the `sim.relay.test` domain, the `+99x` prefix or a `sim:` token. The live plane refuses such an address as `invalid_recipient`."
  @spec reserved?(kind(), String.t()) :: boolean()
  def reserved?(:email, address) do
    domain = address |> String.downcase() |> String.split("@") |> List.last()
    domain == @domain or String.ends_with?(domain, "." <> @domain)
  end

  def reserved?(:phone, number), do: String.starts_with?(number, "+99")
  def reserved?(:token, token), do: String.starts_with?(token, "sim:")

  # CH-72
  # DS-23
  @doc "The provider answer the fake adapter gives for a result, and the event codes that follow an acceptance with their delay in virtual milliseconds."
  @spec answer(result()) ::
          {:accepted, Adapter.accepted()} | {:rejected, Adapter.raw()} | {:uncertain, String.t()}
  def answer("delivered"), do: accepted([{"delivered", 0}])
  def answer("sent_only"), do: accepted([])
  def answer("delayed_delivery"), do: accepted([{"delivered", @delayed_ms}])
  def answer("complaint"), do: accepted([{"delivered", 0}, {"complained", 0}])
  def answer("not_delivered"), do: accepted([{"undelivered", 0}])
  def answer("timeout"), do: {:uncertain, "timeout"}
  def answer("unknown_code"), do: {:rejected, %{code: "sim_unknown_code"}}

  def answer("rate_limited"),
    do: {:rejected, %{code: "rate_limited", status: 429, retry_after_ms: @retry_after_ms}}

  def answer(result) when result in @names, do: {:rejected, %{code: result}}

  defp accepted(followups) do
    list = Enum.map(followups, fn {code, ms} -> %{event_code: code, after_ms: ms} end)
    {:accepted, %{followups: list}}
  end
end
