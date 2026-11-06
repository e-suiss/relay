defmodule Relay.Channels.SettingsCheck do
  @moduledoc """
  The provider settings check of a provider account (CH-14, CH-52): the adapter's `c:Relay.Channels.Adapter.check_settings/1` reads the provider's own settings or status, and the outcome decides the account's verification and health. It is pure: what the outcome leads to is `plan/3`, and the effects are applied by the channels context in one transaction.

  Two modes use it. `:verify` is the verification an operator asks for: a successful check verifies the account, a mismatch fails it with `channel.provider_settings_mismatch`, an adapter without the check fails it closed with `channel.provider_check_unsupported`, and a provider that cannot be asked is tried again by the job queue and, once the attempts are spent, fails it with `channel.provider_check_unavailable`. `:recheck` is the periodic check of a verified account: a mismatch drops it from the verified route the same way, while a success or an unreachable provider only records the account's health; it never verifies an account again, which only a `:verify` check does.

  A mismatch also appends the `provider_account.settings_mismatched` event of the `sender_config` class.
  """

  alias Relay.Channels.Adapter

  @mismatch "channel.provider_settings_mismatch"
  @unsupported "channel.provider_check_unsupported"
  @unavailable "channel.provider_check_unavailable"
  @value_length 128

  @type outcome :: Adapter.check_result() | :unsupported
  @type mode :: :verify | :recheck
  @type plan :: %{
          verification: {String.t(), String.t() | nil} | nil,
          health: String.t() | nil,
          mismatch: map() | nil,
          retry: boolean()
        }

  # CH-14
  # CH-52
  @doc "What a check outcome leads to in a mode; `final?` says that the job's attempts are spent."
  @spec plan(mode(), outcome(), boolean()) :: plan()
  def plan(:verify, :ok, _final?), do: effects({"verified", nil}, "healthy", nil)

  def plan(_mode, {:mismatch, details}, _final?),
    do: effects({"failed", @mismatch}, "degraded", details)

  def plan(:verify, :unsupported, _final?), do: effects({"failed", @unsupported}, nil, nil)
  def plan(:verify, {:error, _reason}, false), do: %{effects(nil, nil, nil) | retry: true}
  def plan(:verify, {:error, _reason}, true), do: effects({"failed", @unavailable}, "down", nil)
  def plan(:recheck, :ok, _final?), do: effects(nil, "healthy", nil)
  def plan(:recheck, {:error, _reason}, _final?), do: effects(nil, "down", nil)
  def plan(:recheck, :unsupported, _final?), do: effects(nil, nil, nil)

  defp effects(verification, health, details) do
    %{verification: verification, health: health, mismatch: mismatch(details), retry: false}
  end

  defp mismatch(nil), do: nil

  defp mismatch(%{} = details) do
    %{
      "setting" => value(Map.get(details, "setting")) || "unknown",
      "expected" => value(Map.get(details, "expected")),
      "actual" => value(Map.get(details, "actual"))
    }
  end

  defp value(text) when is_binary(text), do: String.slice(text, 0, @value_length)
  defp value(_text), do: nil

  @doc "Whether an adapter has the settings check."
  @spec supported?(module()) :: boolean()
  def supported?(adapter) when is_atom(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :check_settings, 1)
  end

  # CH-52
  @doc "The result of a setting that does not hold."
  @spec mismatch(String.t(), String.t() | nil, String.t() | nil) :: {:mismatch, map()}
  def mismatch(setting, expected, actual),
    do: {:mismatch, %{"setting" => setting, "expected" => expected, "actual" => actual}}

  # CH-52
  @doc "Reads the answer of a check call: a `2xx` or `404` answer goes to `fun`, `401` and `403` are a mismatch of the credentials, any other status and a transport failure are an error."
  @spec read(
          {:ok, Req.Response.t()} | {:not_sent, String.t()} | {:uncertain, String.t()},
          (Req.Response.t() -> Adapter.check_result())
        ) :: Adapter.check_result()
  def read({:ok, %Req.Response{status: status} = response}, fun)
      when status in 200..299 or status == 404,
      do: fun.(response)

  def read({:ok, %Req.Response{status: status}}, _fun) when status in [401, 403],
    do: credentials("http_" <> Integer.to_string(status))

  def read({:ok, %Req.Response{status: status}}, _fun),
    do: {:error, "http_" <> Integer.to_string(status)}

  def read({_transport, reason}, _fun) when is_binary(reason), do: {:error, reason}

  @doc "The mismatch of a credential the provider refused or the account lacks."
  @spec credentials(String.t() | nil) :: {:mismatch, map()}
  def credentials(actual), do: mismatch("credentials", "accepted", actual)

  # CH-14
  @doc "`:ok` when every setting of `names` is a non-empty string in `settings`, otherwise the mismatch of the first one that is not."
  @spec required(map() | nil, [String.t()]) :: :ok | {:mismatch, map()}
  def required(settings, names) do
    settings = if is_map(settings), do: settings, else: %{}

    case Enum.find(names, &(not text?(Map.get(settings, &1)))) do
      nil -> :ok
      name -> mismatch(name, "set", nil)
    end
  end

  defp text?(value), do: is_binary(value) and value != ""

  # CH-14
  # TN-28
  @doc "The result of a key store key that could not be used: a key the store does not hold is a mismatch of `setting`, and any other failure is an error."
  @spec key_store(Relay.Error.t(), String.t()) :: {:mismatch, map()} | {:error, String.t()}
  def key_store(%Relay.Error{code: :key_not_found}, setting),
    do: mismatch(setting, "present", "key_not_found")

  def key_store(%Relay.Error{code: code}, _setting), do: {:error, Atom.to_string(code)}

  # CH-34
  @doc "The sending domains of an e-mail account's streams, in order and without duplicates."
  @spec stream_domains(map()) :: [String.t()]
  def stream_domains(%{"settings" => %{"streams" => %{} = streams}}) do
    streams
    |> Enum.sort()
    |> Enum.flat_map(fn
      {_stream, %{"domain" => domain}} when is_binary(domain) and domain != "" -> [domain]
      _other -> []
    end)
    |> Enum.uniq()
  end

  def stream_domains(_account), do: []
end
