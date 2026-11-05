defmodule Relay.Channels.Push.Failures do
  @moduledoc """
  The failure mapping tables of the push providers (CH-7, CH-71): every APNs, FCM HTTP v1 and Web Push response code maps to one failure class, and retry, fallback, token disabling and breaker weight derive from that class alone. The tables are data under `priv/channels/<provider>/failures.json`, compiled from the providers' published documentation with the source and compilation date in the file; every rule has a test vector in `vectors.json` beside it.

  A code without a rule is `unknown`; it is never guessed (CH-8). APNs rules match the HTTP status and the `reason`, falling back to a status-only rule; FCM rules match the `FcmError` `errorCode` first, then the `google.rpc` status, then the HTTP status; Web Push rules match the HTTP status.
  """

  @root Path.expand("../../../../priv/channels", __DIR__)
  @providers [:apns, :fcm, :web_push]

  @paths Map.new(@providers, &{&1, Path.join([@root, Atom.to_string(&1), "failures.json"])})
  for {_provider, path} <- @paths, do: @external_resource(path)
  @tables Map.new(@paths, fn {provider, path} -> {provider, Jason.decode!(File.read!(path))} end)

  @fcm_error "type.googleapis.com/google.firebase.fcm.v1.FcmError"
  @class_atoms %{
    "transient" => :transient,
    "permanent_target" => :permanent_target,
    "permanent_content" => :permanent_content,
    "policy" => :policy,
    "quota" => :quota,
    "auth" => :auth,
    "sender_config" => :sender_config,
    "unknown" => :unknown
  }

  @type provider :: :apns | :fcm | :web_push
  @type class ::
          :transient
          | :permanent_target
          | :permanent_content
          | :policy
          | :quota
          | :auth
          | :sender_config
          | :unknown

  @typedoc "An HTTP response; the body is raw or decoded JSON."
  @type response :: %{status: pos_integer(), body: binary() | map() | nil}

  @typedoc "A classified failure: the class, the matched rule (`nil` for `unknown`), the provider's raw code and, for an APNs 410, the time the token became invalid in Unix milliseconds."
  @type failure :: %{
          class: class(),
          rule: String.t() | nil,
          provider_code: String.t(),
          unregistered_at: integer() | nil
        }

  @doc "The providers with a table."
  @spec providers() :: [provider(), ...]
  def providers, do: @providers

  # CH-71
  @doc "The table of a provider as data: `provider`, `source`, `compiled_at` and `rules`."
  @spec table(provider()) :: map()
  def table(provider) when provider in @providers, do: Map.fetch!(@tables, provider)

  # CH-7
  # CH-8
  # CH-11
  @doc "Classifies a provider response; a 2xx response is `:accepted`, which is never a delivery."
  @spec classify(provider(), response()) :: :accepted | {:failure, failure()}
  def classify(provider, %{status: status}) when provider in @providers and status in 200..299,
    do: :accepted

  def classify(provider, %{status: status} = response) when provider in @providers do
    body = decode(Map.get(response, :body))
    {rule, code} = match(provider, status, body, Map.fetch!(@tables, provider)["rules"])

    {:failure,
     %{
       class: Map.fetch!(@class_atoms, if(rule, do: rule["class"], else: "unknown")),
       rule: rule && rule["id"],
       provider_code: code,
       unregistered_at: unregistered_at(provider, status, body)
     }}
  end

  defp match(:apns, status, body, rules) do
    reason = if is_map(body), do: body["reason"]
    exact = reason && Enum.find(rules, &(&1["status"] == status and &1["reason"] == reason))
    any = Enum.find(rules, &(&1["status"] == status and &1["reason"] == nil))
    {exact || any, Enum.join([status | List.wrap(reason)], "/")}
  end

  defp match(:fcm, status, body, rules) do
    error = if is_map(body) and is_map(body["error"]), do: body["error"], else: %{}
    error_code = error_code(error)
    rpc = if is_binary(error["status"]), do: error["status"]

    by_code = error_code && Enum.find(rules, &(&1["error_code"] == error_code))
    by_rpc = rpc && Enum.find(rules, &(&1["error_code"] == nil and &1["status"] == rpc))
    rule = by_code || by_rpc || Enum.find(rules, &(&1["http_status"] == status))

    {rule, Enum.join([status | Enum.reject([rpc, error_code], &is_nil/1)], "/")}
  end

  defp match(:web_push, status, _body, rules),
    do: {Enum.find(rules, &(&1["status"] == status)), Integer.to_string(status)}

  defp error_code(%{"details" => details}) when is_list(details),
    do: Enum.find_value(details, &fcm_error/1)

  defp error_code(_error), do: nil

  defp fcm_error(%{"@type" => @fcm_error, "errorCode" => code}) when is_binary(code), do: code
  defp fcm_error(_detail), do: nil

  defp unregistered_at(:apns, 410, %{"timestamp" => ms}) when is_integer(ms), do: ms
  defp unregistered_at(_provider, _status, _body), do: nil

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode(body), do: body
end
