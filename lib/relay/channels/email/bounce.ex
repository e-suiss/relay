defmodule Relay.Channels.Email.Bounce do
  @moduledoc """
  Bounce and complaint classification (CH-39, CH-40). A DSN recipient (`Relay.Channels.Email.Dsn`) or a feedback report (`Relay.Channels.Email.Arf`) gets a bounce kind of §12.6.5 and the provider failure class of §12.2 it maps to, with what follows from it:

  | Kind | Failure class | Subscriber | Reputation counter |
  |---|---|---|---|
  | `hard` | `permanent_target` | suppressed at once, without end (`hard_bounce`) | bounce |
  | `soft` | `transient` | counted toward a timed suppression (`soft_bounce`) | — |
  | `complaint` | `policy` | suppressed at once (`complaint`) | complaint |
  | `sender_config` | `sender_config` | never suppressed; a domain or tenant event and the breaker | — |
  | `policy` | `permanent_content` | never suppressed | bounce |
  | `content` | `permanent_content` | never suppressed | — |
  | `unknown` | `unknown` | never suppressed; `provider.unknown_code` and an alarm | — |

  A `delayed` DSN (the MTA is still trying) and a `delivered`, `relayed` or `expanded` one are outcomes, not failures, and carry no class; so does a `not-spam` feedback report.

  The status of a failed recipient is matched against the `email_bounce_codes` data set: the exact code first, then a dialect (only for a permanent or missing status), then the longest prefix. A generic `X.0.0` status whose diagnostic names a more specific code of the same class is read as that code. Anything else is `unknown`; nothing is guessed (CH-8, CH-77).
  """

  alias Relay.Channels.Email.Arf
  alias Relay.Channels.Email.Dsn
  alias Relay.Channels.Email.StatusCode
  alias Relay.Redacted

  @type kind ::
          :hard
          | :soft
          | :complaint
          | :sender_config
          | :policy
          | :content
          | :unknown
          | :delayed
          | :delivered
          | :not_spam

  @type t :: %{
          kind: kind(),
          failure_class: String.t() | nil,
          suppression: String.t() | nil,
          reputation: :bounce | :complaint | nil,
          status: String.t() | nil,
          rule: String.t() | nil
        }

  @kinds %{
    "hard" => :hard,
    "soft" => :soft,
    "sender_config" => :sender_config,
    "policy" => :policy,
    "content" => :content
  }

  @effects %{
    hard: {"permanent_target", "hard_bounce", :bounce},
    soft: {"transient", "soft_bounce", nil},
    complaint: {"policy", "complaint", :complaint},
    sender_config: {"sender_config", nil, nil},
    policy: {"permanent_content", nil, :bounce},
    content: {"permanent_content", nil, nil},
    unknown: {"unknown", nil, nil},
    delayed: {nil, nil, nil},
    delivered: {nil, nil, nil},
    not_spam: {nil, nil, nil}
  }

  @complaints ["abuse", "fraud", "virus", "other"]

  # CH-39
  # CH-77
  @doc """
  Classifies a received report: a feedback report yields one result, a delivery status notification one result per recipient. A message that is neither is `{:unknown, [result]}` with the `unknown` kind (CH-77).
  """
  @spec classify_message(binary(), map()) ::
          {:arf, Arf.t(), t()} | {:dsn, Dsn.t(), [t()]} | {:unknown, [t()]}
  def classify_message(message, table) when is_binary(message) do
    case Arf.parse(message) do
      {:ok, report} ->
        {:arf, report, classify_feedback(report)}

      {:error, :invalid_report} ->
        {:unknown, [result(:unknown, nil, "arf:invalid")]}

      {:error, :not_a_report} ->
        case Dsn.parse(message) do
          {:ok, report} -> {:dsn, report, Enum.map(report.recipients, &classify(&1, table))}
          {:error, :not_a_report} -> {:unknown, [result(:unknown, nil, nil)]}
        end
    end
  end

  # CH-39
  # CH-37
  @doc "Classifies a feedback report: `abuse`, `fraud`, `virus` and `other` are complaints, `auth-failure` (RFC 6591) is a sender configuration event, `not-spam` is no failure; any other type is `unknown`."
  @spec classify_feedback(Arf.t()) :: t()
  def classify_feedback(%{feedback_type: type}) do
    rule = "arf:" <> type

    cond do
      type in @complaints -> result(:complaint, nil, rule)
      type == "auth-failure" -> result(:sender_config, nil, rule)
      type == "not-spam" -> result(:not_spam, nil, rule)
      true -> result(:unknown, nil, rule)
    end
  end

  # CH-39
  # CH-8
  @doc "Classifies one DSN recipient against the content of the `email_bounce_codes` data set."
  @spec classify(Dsn.recipient(), map()) :: t()
  def classify(%{action: action} = recipient, table) do
    diagnostic = recipient.diagnostic |> expose() |> String.downcase(:ascii)
    status = effective_status(recipient.status, diagnostic)
    text = status && StatusCode.to_string(status)

    case action do
      "delayed" -> result(:delayed, text, nil)
      done when done in ["delivered", "relayed", "expanded"] -> result(:delivered, text, nil)
      _failed -> failed(status, text, diagnostic, table)
    end
  end

  defp failed(status, text, diagnostic, table) do
    with :none <- code(text, table),
         :none <- dialect(status, diagnostic, table),
         :none <- prefix(text, table) do
      result(:unknown, text, nil)
    else
      {kind, rule} -> result(kind, text, rule)
    end
  end

  defp effective_status({class, 0, 0} = status, diagnostic) do
    case StatusCode.find(diagnostic) do
      {:ok, {^class, subject, _detail} = found} when subject != 0 -> found
      _other -> status
    end
  end

  defp effective_status(nil, diagnostic) do
    case StatusCode.find(diagnostic) do
      {:ok, found} -> found
      :error -> nil
    end
  end

  defp effective_status(status, _diagnostic), do: status

  defp dialect({class, _subject, _detail}, _diagnostic, _table) when class != 5, do: :none

  defp dialect(_status, diagnostic, table) do
    case Enum.find(table["dialects"], &String.contains?(diagnostic, &1["contains"])) do
      nil -> :none
      row -> {Map.fetch!(@kinds, row["kind"]), "dialect:" <> row["id"]}
    end
  end

  defp code(nil, _table), do: :none

  defp code(text, table) do
    case Enum.find(table["codes"], &(&1["code"] == text)) do
      nil -> :none
      row -> {Map.fetch!(@kinds, row["kind"]), "code:" <> text}
    end
  end

  defp prefix(nil, _table), do: :none

  defp prefix(text, table) do
    table["prefixes"]
    |> Enum.filter(&(text == &1["prefix"] or String.starts_with?(text, &1["prefix"] <> ".")))
    |> Enum.max_by(&byte_size(&1["prefix"]), fn -> nil end)
    |> case do
      nil -> :none
      row -> {Map.fetch!(@kinds, row["kind"]), "prefix:" <> row["prefix"]}
    end
  end

  defp expose(nil), do: ""
  defp expose(value), do: value |> Redacted.expose() |> to_text()

  defp to_text(value) when is_binary(value), do: value
  defp to_text(_value), do: ""

  defp result(kind, status, rule) do
    {failure_class, suppression, reputation} = Map.fetch!(@effects, kind)

    %{
      kind: kind,
      failure_class: failure_class,
      suppression: suppression,
      reputation: reputation,
      status: status,
      rule: rule
    }
  end

  # CH-39
  @doc "Whether a result never touches the subscriber: every kind but `hard`, `soft` and `complaint`. A `sender_config` result never suppresses."
  @spec subscriber_untouched?(t()) :: boolean()
  def subscriber_untouched?(%{suppression: suppression}), do: suppression == nil

  # CH-8
  @doc "Whether a result must raise `provider.unknown_code` and an operator alarm."
  @spec unknown_code?(t()) :: boolean()
  def unknown_code?(%{kind: kind}), do: kind == :unknown

  # CH-40
  @doc """
  Decides a soft bounce against the `soft_bounce` parameters of the `email_reputation` data set: `soft_bounces` are the times (milliseconds) of the address's earlier soft bounces, `now` the time of this one. Below `count` inside `window_ms` it is `:count`; at `count` it is `{:suppress, expires_at_ms}` when the parameters carry `suppress_ms`, and `:no_duration` when they do not, in which case no timed suppression is written.
  """
  @spec soft_bounce([integer()], integer(), map()) ::
          :count | {:suppress, integer()} | :no_duration
  def soft_bounce(soft_bounces, now, %{"window_ms" => window_ms, "count" => count} = params)
      when is_list(soft_bounces) and is_integer(now) do
    recent = Enum.count(soft_bounces, &(&1 > now - window_ms and &1 <= now)) + 1

    cond do
      recent < count -> :count
      is_integer(params["suppress_ms"]) -> {:suppress, now + params["suppress_ms"]}
      true -> :no_duration
    end
  end
end
