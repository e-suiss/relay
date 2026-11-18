defmodule Relay.Api.PreviewSandbox do
  @moduledoc """
  The sandboxed preview origin (TP-24, TP-39). Rendered e-mail HTML of a preview is displayed only on a host of its own, configured with `config :relay, Relay.Api.PreviewSandbox, host: "preview.relay.example"` (`RELAY_PREVIEW_HOST`), never on Relay's API host. A preview hands the HTML to `put/2`, which keeps it on Valkey for five minutes under an opaque link: the tenant, the environment and 32 random bytes, of which Valkey holds only a digest. The link is the only authority of the page, which needs no credential and changes nothing. Without a configured host there is no link, and the output of a `raw_html` cell or of a template that allows `| raw` is never shown.
  """

  @ttl_ms 300_000
  @secret_bytes 32
  @prefix "/sandbox/"

  @type put_result :: {:ok, String.t()} | :unconfigured | {:error, Relay.Error.t()}

  # TP-39
  @doc "The configured preview host, or `nil` when there is none."
  @spec host() :: String.t() | nil
  def host do
    case Keyword.get(Application.get_env(:relay, __MODULE__, []), :host) do
      host when is_binary(host) and host != "" -> String.downcase(host)
      _none -> nil
    end
  end

  # TP-39
  @doc "Seconds a preview link stays readable."
  @spec ttl_s() :: pos_integer()
  def ttl_s, do: div(@ttl_ms, 1000)

  # TP-39
  @doc "Keeps a rendered HTML page of a scope for the sandbox origin and returns its link."
  @spec put(Relay.Scope.t(), String.t()) :: put_result()
  def put(%Relay.Scope{} = scope, html) when is_binary(html) do
    case host() do
      nil -> :unconfigured
      host -> store(scope, html, host)
    end
  end

  defp store(scope, html, host) do
    secret = Relay.Random.bytes(@secret_bytes)

    case Relay.Platform.put_short_lived(scope, segments(secret), html, @ttl_ms) do
      :ok -> {:ok, "https://" <> host <> @prefix <> token(scope, secret)}
      {:error, error} -> {:error, error}
    end
  end

  # TP-39
  @doc "Reads the page behind a link: `:not_found` for a malformed, unknown or expired link."
  @spec fetch(String.t()) :: {:ok, String.t()} | {:error, :not_found | :unavailable}
  def fetch(token) when is_binary(token) do
    with {:ok, scope, secret} <- parse(token),
         {:ok, html} when is_binary(html) <- read(scope, secret) do
      {:ok, html}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, %Relay.Error{}} -> {:error, :unavailable}
      _invalid -> {:error, :not_found}
    end
  end

  defp read(scope, secret), do: Relay.Platform.get_short_lived(scope, segments(secret))

  defp token(scope, secret) do
    env = if scope.environment == :live, do: 0, else: 1
    Base.url_encode64(scope.tenant_id <> <<env>> <> secret, padding: false)
  end

  defp parse(token) do
    with {:ok, <<tenant::binary-size(16), env, secret::binary-size(@secret_bytes)>>} <-
           Base.url_decode64(token, padding: false),
         {:ok, environment} <- environment(env),
         {:ok, scope} <- Relay.Scope.new(tenant, environment) do
      {:ok, scope, secret}
    else
      _invalid -> :error
    end
  end

  defp environment(0), do: {:ok, :live}
  defp environment(1), do: {:ok, :test}
  defp environment(_other), do: :error

  defp segments(secret),
    do: ["preview_sandbox", Base.encode16(:crypto.hash(:sha256, secret), case: :lower)]
end
