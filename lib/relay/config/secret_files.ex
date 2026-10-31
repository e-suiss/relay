defmodule Relay.Config.SecretFiles do
  @moduledoc """
  The sensitive process that reads the node's installation secrets from files: the database passwords, the audit object store key and the endpoint's `secret_key_base`. The application environment holds only the file paths (`config :relay, Relay.Config.SecretFiles, repo: path, ...`); a secret is read when a consumer asks for it, so a rotated file is picked up on the next connection, and it is never stored in this process's state, in the application environment or in shared memory.

  Database connections take their password through `configure/2`, the Postgrex `:configure` callback that runs in the connection process before every connect attempt and marks that process sensitive. A connection whose password file is part of its own configuration takes it through `configure_path/2`. Other consumers get a zero-arity callback, `{Relay.Config.SecretFiles, :fetch!, [name]}`, which they call at the moment they use the secret. The endpoint reads `secret_key_base` when it starts (`RelayWeb.Endpoint.supervised/0`).
  """

  use GenServer

  alias Relay.Hygiene
  alias Relay.Redacted

  @names [:repo, :queue_repo, :maint_repo, :audit_s3, :secret_key_base]
  @timeout_ms 5_000

  @type name :: :repo | :queue_repo | :maint_repo | :audit_s3 | :secret_key_base

  @doc "Secret names a node can be configured with."
  @spec names() :: [name(), ...]
  def names, do: @names

  @doc "Starts the process under its registered name with the file paths of the application environment."
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg \\ []) do
    paths = Application.get_env(:relay, __MODULE__, [])
    GenServer.start_link(__MODULE__, paths, name: __MODULE__)
  end

  @doc "Starts the process unless it is running; for release commands that run without the supervision tree."
  @spec ensure_started() :: :ok
  def ensure_started do
    case start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  # TN-67 (3)
  # T-46
  @doc "Reads the secret `name` from its file, redacted."
  @spec fetch(name()) :: {:ok, Redacted.t()} | {:error, Relay.Error.t()}
  def fetch(name) when name in @names, do: GenServer.call(__MODULE__, {:fetch, name}, @timeout_ms)

  @doc "Like `fetch/1`, raising when the secret cannot be read."
  @spec fetch!(name()) :: Redacted.t()
  def fetch!(name) do
    case fetch(name) do
      {:ok, secret} -> secret
      {:error, error} -> raise Relay.Config.Error, "secret #{name}: #{error.message}"
    end
  end

  # TN-68 (1)
  @doc "Returns true if the secret `name` has a file configured."
  @spec configured?(name()) :: boolean()
  def configured?(name) when name in @names,
    do: GenServer.call(__MODULE__, {:configured?, name}, @timeout_ms)

  # TN-67 (3)
  @doc "Postgrex `:configure` callback: marks the connection process sensitive and adds the password of `name` to the connect options."
  @spec configure(keyword(), name()) :: keyword()
  def configure(opts, name) when is_list(opts) do
    :ok = Hygiene.sensitive!()
    Keyword.put(opts, :password, Redacted.expose(fetch!(name)))
  end

  # TN-67 (3)
  # T-41
  @doc "Postgrex `:configure` callback for a connection whose password file path is part of its own configuration, such as the source database of an ingest connector: marks the connection process sensitive and adds the password read from `path`."
  @spec configure_path(keyword(), Path.t()) :: keyword()
  def configure_path(opts, path) when is_list(opts) and is_binary(path) and path != "" do
    :ok = Hygiene.sensitive!()

    case read(path) do
      {:ok, secret} -> Keyword.put(opts, :password, Redacted.expose(secret))
      {:error, reason} -> raise Relay.Config.Error, "secret file unavailable: #{inspect(reason)}"
    end
  end

  @impl GenServer
  def init(paths) do
    :ok = Hygiene.sensitive!()

    case Enum.find(paths, &invalid?/1) do
      nil -> init_read(Map.new(paths))
      {name, _path} -> {:stop, {:invalid_secret_file, name}}
    end
  end

  defp init_read(paths) do
    case Enum.find(paths, fn {_name, path} -> match?({:error, _}, read(path)) end) do
      nil -> {:ok, paths}
      {name, _path} -> {:stop, {:unreadable_secret_file, name}}
    end
  end

  @impl GenServer
  def handle_call({:configured?, name}, _from, paths),
    do: {:reply, Map.has_key?(paths, name), paths}

  def handle_call({:fetch, name}, _from, paths) do
    reply =
      with {:ok, path} <- path(paths, name),
           {:ok, secret} <- read(path) do
        {:ok, secret}
      else
        {:error, reason} ->
          {:error,
           Relay.Error.new(:secret_unavailable, "secret file unavailable", %{
             name: name,
             reason: reason
           })}
      end

    {:reply, reply, paths}
  end

  @impl GenServer
  def format_status(status), do: Hygiene.format_status(status, & &1)

  defp invalid?({name, path}), do: name not in @names or not is_binary(path) or path == ""
  defp invalid?(_entry), do: true

  defp path(paths, name) do
    case paths do
      %{^name => path} -> {:ok, path}
      _ -> {:error, :not_configured}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    case File.read(path) do
      {:ok, content} ->
        case String.trim_trailing(content, "\n") do
          "" -> {:error, :empty}
          secret -> {:ok, Redacted.wrap(secret)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
