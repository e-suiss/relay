defmodule Relay.CLI.Config do
  @moduledoc """
  Configuration of the command line tool, from options, environment variables and an optional profile file, in that order of precedence.

  * The Relay API URL: `--api-url`, `RELAY_API_URL` or the profile's `api_url`.
  * The Access issuer: `--issuer`, `RELAY_ACCESS_ISSUER` or the profile's `access_issuer`. The token endpoint is discovered from it.
  * The environment of the API client, `test` or `live`: `--env`, `RELAY_ENVIRONMENT` or the profile's `environment`. It is required, because an API client belongs to one environment and nothing in a request can choose it.
  * The API client of an environment: `--client-id` and `--client-secret-file` for the chosen environment; `RELAY_TEST_CLIENT_ID` or `RELAY_LIVE_CLIENT_ID` with `RELAY_TEST_CLIENT_SECRET[_FILE]` or `RELAY_LIVE_CLIENT_SECRET[_FILE]`; `RELAY_CLIENT_ID` with `RELAY_CLIENT_SECRET[_FILE]` for the chosen environment; or the profile's `test` and `live` objects with `client_id` and `client_secret_file`. A profile holds no secret itself.
  * Optional: the scopes to request (`--scope`, `RELAY_SCOPE`, `scope`) and the API version (`--api-version`, `RELAY_API_VERSION`, `api_version`).

  The profile file is `--config`, `RELAY_CONFIG` or `$XDG_CONFIG_HOME/relay/config.json` (`~/.config/relay/config.json`): a JSON object `{"profiles": {"<name>": {...}}}`; the profile is `--profile`, `RELAY_PROFILE` or `default`. URLs use https; plain http is accepted only for a loopback address.

  `promote` always moves a workflow from `test` to `live` and needs both API clients.
  """

  alias Relay.CLI.Failure
  alias Relay.CLI.Files

  @enforce_keys [:api_url, :issuer, :environment, :credentials]
  defstruct [:api_url, :issuer, :environment, :api_version, :scope, :credentials]

  @type environment :: :test | :live
  @type credential :: %{client_id: String.t(), client_secret: Relay.Redacted.t()}
  @type t :: %__MODULE__{
          api_url: String.t(),
          issuer: String.t(),
          environment: environment(),
          api_version: String.t() | nil,
          scope: String.t() | nil,
          credentials: %{optional(environment()) => credential()}
        }

  @profile_keys ~w(api_url access_issuer environment api_version scope test live)
  @client_keys ~w(client_id client_secret_file)

  # X-33
  # API-42
  # E-78
  @doc "Resolves the configuration of a command; `:promote` resolves both API clients and targets `live`."
  @spec load(keyword(), %{optional(String.t()) => String.t()}, :selected | :promote) ::
          {:ok, t()} | {:error, Failure.t()}
  def load(opts, env, mode) when mode in [:selected, :promote] do
    case profile(opts, env) do
      {:ok, profile} -> resolve(opts, env, profile, mode)
      {:error, _failure} = error -> error
    end
  end

  # API-41
  @doc "Returns true for an https URL with a host, or an http URL whose host is a loopback address."
  @spec secure_url?(String.t()) :: boolean()
  def secure_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" -> true
      %URI{scheme: "http", host: host, userinfo: nil} when is_binary(host) -> loopback?(host)
      _other -> false
    end
  end

  # API-64
  @doc "Returns true if a host name is `localhost` or a loopback IP address."
  @spec loopback?(String.t()) :: boolean()
  def loopback?("localhost"), do: true

  def loopback?(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _b, _c, _d}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _other -> false
    end
  end

  defp resolve(opts, env, profile, mode) do
    api_url = pick([opts[:api_url], env["RELAY_API_URL"], profile["api_url"]])
    issuer = pick([opts[:issuer], env["RELAY_ACCESS_ISSUER"], profile["access_issuer"]])
    environment = pick([opts[:env], env["RELAY_ENVIRONMENT"], profile["environment"]])
    api_version = pick([opts[:api_version], env["RELAY_API_VERSION"], profile["api_version"]])
    scope = pick([opts[:scope], env["RELAY_SCOPE"], profile["scope"]])

    with {:ok, api_url} <- url(api_url, "--api-url"),
         {:ok, issuer} <- url(issuer, "--issuer"),
         {:ok, declared} <- declared(environment),
         {:ok, environment, needed} <- environments(declared, opts[:env], mode),
         {:ok, api_version} <- api_version(api_version),
         {:ok, credentials} <- credentials(needed, declared, opts, env, profile) do
      {:ok,
       %__MODULE__{
         api_url: api_url,
         issuer: issuer,
         environment: environment,
         api_version: api_version,
         scope: scope,
         credentials: credentials
       }}
    end
  end

  defp profile(opts, env) do
    explicit = pick([opts[:config], env["RELAY_CONFIG"]])
    name = pick([opts[:profile], env["RELAY_PROFILE"]])

    with {:ok, document} <- profile_file(explicit || default_path(env), explicit != nil),
         {:ok, profile} <- select(document, name) do
      validate(profile)
    end
  end

  defp default_path(env) do
    cond do
      present?(env["XDG_CONFIG_HOME"]) ->
        Path.join([env["XDG_CONFIG_HOME"], "relay", "config.json"])

      present?(env["HOME"]) ->
        Path.join([env["HOME"], ".config", "relay", "config.json"])

      true ->
        nil
    end
  end

  defp profile_file(nil, _explicit?), do: {:ok, %{}}

  defp profile_file(path, explicit?) do
    case Files.read(Path.expand(path)) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{} = document} -> {:ok, document}
          _other -> usage("#{path} is not a JSON object")
        end

      {:error, :enoent} when not explicit? ->
        {:ok, %{}}

      {:error, reason} ->
        usage(Files.describe(path, reason))
    end
  end

  defp select(document, name) do
    profiles = Map.get(document, "profiles", %{})

    cond do
      Map.keys(document) -- ["profiles"] != [] ->
        usage("the configuration file has unknown keys")

      not is_map(profiles) ->
        usage("profiles must be a JSON object")

      is_nil(name) ->
        {:ok, Map.get(profiles, "default", %{})}

      Map.has_key?(profiles, name) ->
        {:ok, Map.fetch!(profiles, name)}

      true ->
        usage("profile #{name} is not in the configuration file")
    end
  end

  defp validate(%{} = profile) do
    clients = Map.take(profile, ["test", "live"])
    scalars = Map.drop(profile, ["test", "live"])

    cond do
      Map.keys(profile) -- @profile_keys != [] ->
        usage("the profile has unknown keys; allowed: " <> Enum.join(@profile_keys, ", "))

      not Enum.all?(scalars, fn {_key, value} -> is_binary(value) end) ->
        usage("profile values must be strings")

      not Enum.all?(clients, fn {_key, client} -> client?(client) end) ->
        usage("profile test and live objects take only client_id and client_secret_file")

      true ->
        {:ok, profile}
    end
  end

  defp validate(_profile), do: usage("a profile must be a JSON object")

  defp client?(%{} = client) do
    Map.keys(client) -- @client_keys == [] and Enum.all?(Map.values(client), &is_binary/1)
  end

  defp client?(_client), do: false

  defp url(nil, option), do: usage("#{option} is not configured")

  defp url(value, option) do
    case URI.parse(value) do
      %URI{query: nil, fragment: nil} ->
        if secure_url?(value),
          do: {:ok, String.trim_trailing(value, "/")},
          else: usage("#{option} must be an https URL (http only for a loopback address)")

      _other ->
        usage("#{option} must not carry a query or fragment")
    end
  end

  defp declared(nil), do: {:ok, nil}
  defp declared("test"), do: {:ok, :test}
  defp declared("live"), do: {:ok, :live}
  defp declared(other), do: usage("the environment must be test or live, not #{other}")

  defp environments(nil, _flag, :selected),
    do: usage("choose the API client environment with --env test|live or RELAY_ENVIRONMENT")

  defp environments(declared, _flag, :selected), do: {:ok, declared, [declared]}

  defp environments(_declared, flag, :promote) when flag in [nil, "live"],
    do: {:ok, :live, [:test, :live]}

  defp environments(_declared, _flag, :promote),
    do: usage("promote always moves a workflow from test to live; drop --env or pass --env live")

  defp api_version(nil), do: {:ok, nil}

  defp api_version(value) do
    if Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, value),
      do: {:ok, value},
      else: usage("the API version is a date such as 2026-11-01")
  end

  defp credentials(needed, declared, opts, env, profile) do
    Enum.reduce_while(needed, {:ok, %{}}, fn environment, {:ok, acc} ->
      case credential(environment, environment == declared, opts, env, profile) do
        {:ok, credential} -> {:cont, {:ok, Map.put(acc, environment, credential)}}
        {:error, _failure} = error -> {:halt, error}
      end
    end)
  end

  defp credential(environment, chosen?, opts, env, profile) do
    prefix = "RELAY_" <> String.upcase(Atom.to_string(environment)) <> "_"
    client = Map.get(profile, Atom.to_string(environment), %{})

    id =
      pick([
        if_chosen(chosen?, opts[:client_id]),
        env[prefix <> "CLIENT_ID"],
        if_chosen(chosen?, env["RELAY_CLIENT_ID"]),
        client["client_id"]
      ])

    sources = [
      file(if_chosen(chosen?, opts[:client_secret_file])),
      value(env[prefix <> "CLIENT_SECRET"]),
      file(env[prefix <> "CLIENT_SECRET_FILE"]),
      value(if_chosen(chosen?, env["RELAY_CLIENT_SECRET"])),
      file(if_chosen(chosen?, env["RELAY_CLIENT_SECRET_FILE"])),
      file(client["client_secret_file"])
    ]

    secret = Enum.find(sources, &(&1 != nil))

    with {:ok, id} <- required(id, "no #{environment} API client id: set #{prefix}CLIENT_ID"),
         {:ok, secret} <-
           required(secret, "no #{environment} client secret: set #{prefix}CLIENT_SECRET_FILE"),
         {:ok, secret} <- secret(secret) do
      {:ok, %{client_id: id, client_secret: secret}}
    end
  end

  defp if_chosen(true, value), do: value
  defp if_chosen(false, _value), do: nil

  defp value(value), do: if(present?(value), do: {:value, value})
  defp file(path), do: if(present?(path), do: {:file, path})

  defp required(nil, message), do: usage(message)
  defp required(value, _message), do: {:ok, value}

  defp secret({:value, value}), do: {:ok, Relay.Redacted.wrap(value)}

  defp secret({:file, path}) do
    case Files.read(Path.expand(path)) do
      {:ok, content} ->
        case String.trim(content) do
          "" -> usage("the client secret file #{path} is empty")
          secret -> {:ok, Relay.Redacted.wrap(secret)}
        end

      {:error, reason} ->
        usage(Files.describe(path, reason))
    end
  end

  defp pick(values), do: Enum.find(values, &present?/1)

  defp present?(value), do: is_binary(value) and value != ""

  defp usage(message), do: {:error, Failure.new(:usage, "configuration_error", message)}
end
