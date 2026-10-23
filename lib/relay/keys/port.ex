defmodule Relay.Keys.Port do
  @moduledoc """
  `Relay.Keys` implementation that owns the `pkcs11_port` OS process. The program's SHA-256 is checked before every start against the checksum embedded at compile time from `priv/native/pkcs11_port.sha256`, which the release build writes next to the program it bundles; a crash or a timed-out request closes the program, fails the requests in flight with `:key_store_unavailable` and reopens it with backoff, so the server itself never crashes on the program's behalf.
  """

  @behaviour Relay.Keys

  use GenServer

  require Logger

  alias Relay.Error
  alias Relay.Keys.Protocol
  alias Relay.Redacted

  @default_timeout 5_000
  @min_backoff 100
  @max_backoff 30_000
  @max_id 0xFFFFFFFF
  @program "priv/native/pkcs11_port"
  @checksum_file Path.expand("../../../#{@program}.sha256", __DIR__)
  @external_resource @checksum_file
  @embedded_sha256 (with {:ok, content} <- File.read(@checksum_file),
                         [hash | _] <- String.split(content),
                         true <- hash =~ ~r/\A[0-9a-fA-F]{64}\z/ do
                      String.downcase(hash)
                    else
                      _ -> nil
                    end)

  @type option ::
          {:name, GenServer.name()}
          | {:executable, Path.t()}
          | {:module, Path.t()}
          | {:token, String.t()}
          | {:pin_file, Path.t()}
          | {:sha256, String.t() | nil}
          | {:timeout, pos_integer()}
          | {:min_backoff, pos_integer()}
          | {:max_backoff, pos_integer()}

  # TN-63
  # T-53
  # TN-65 (7)
  @doc "Starts the server. `:module`, `:token` and `:pin_file` are required; the PIN is read by the program from `:pin_file` and never enters the VM. `:executable` defaults to the program bundled in the release and `:sha256` to the embedded checksum."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Relay.Keys
  @doc "Checks that the program answers. See `Relay.Keys.ping/0`."
  @spec ping(GenServer.server()) :: :ok | {:error, Error.t()}
  def ping(server \\ __MODULE__), do: request(server, :ping)

  @impl Relay.Keys
  @doc "Signs through the program. See `Relay.Keys.sign/3`."
  @spec sign(GenServer.server(), Relay.Keys.alg(), String.t(), binary()) ::
          {:ok, binary()} | {:error, Error.t()}
  def sign(server \\ __MODULE__, alg, label, message),
    do: request(server, {:sign, alg, label, message})

  @impl Relay.Keys
  @doc "Exports a public key through the program. See `Relay.Keys.public_key/2`."
  @spec public_key(GenServer.server(), Relay.Keys.alg(), String.t()) ::
          {:ok, Relay.Keys.public_key()} | {:error, Error.t()}
  def public_key(server \\ __MODULE__, alg, label),
    do: request(server, {:public_key, alg, label})

  @impl Relay.Keys
  @doc "Wraps a data key through the program. See `Relay.Keys.wrap/3`."
  @spec wrap(GenServer.server(), String.t(), binary(), Redacted.t()) ::
          {:ok, binary()} | {:error, Error.t()}
  def wrap(server \\ __MODULE__, label, aad, data_key),
    do: request(server, {:wrap, label, aad, fn -> Redacted.expose(data_key) end})

  @impl Relay.Keys
  @doc "Unwraps a data key through the program. See `Relay.Keys.unwrap/3`."
  @spec unwrap(GenServer.server(), String.t(), binary(), binary()) ::
          {:ok, Redacted.t()} | {:error, Error.t()}
  def unwrap(server \\ __MODULE__, label, aad, wrapped),
    do: request(server, {:unwrap, label, aad, wrapped})

  @impl Relay.Keys
  @doc "Computes an HMAC inside the token through the program. See `Relay.Keys.hmac_sha256/2`."
  @spec hmac_sha256(GenServer.server(), String.t(), Redacted.t()) ::
          {:ok, <<_::256>>} | {:error, Error.t()}
  def hmac_sha256(server \\ __MODULE__, label, message),
    do: request(server, {:hmac, label, fn -> Redacted.expose(message) end})

  @impl Relay.Keys
  @doc "Reads a secret data object through the program. See `Relay.Keys.read_secret/1`."
  @spec read_secret(GenServer.server(), String.t()) :: {:ok, Redacted.t()} | {:error, Error.t()}
  def read_secret(server \\ __MODULE__, label), do: request(server, {:read_secret, label})

  defp request(server, request) do
    GenServer.call(server, {:request, request}, :infinity)
  catch
    :exit, _reason -> unavailable("key store server is not running")
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:sensitive, true)
    Process.flag(:trap_exit, true)

    state = %{
      executable: Keyword.get_lazy(opts, :executable, &bundled_program/0),
      sha256: Keyword.get(opts, :sha256, @embedded_sha256),
      args: args(opts),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      min_backoff: Keyword.get(opts, :min_backoff, @min_backoff),
      max_backoff: Keyword.get(opts, :max_backoff, @max_backoff),
      backoff: Keyword.get(opts, :min_backoff, @min_backoff),
      port: nil,
      down: unavailable_error("key store program is starting"),
      next_id: 1,
      pending: %{}
    }

    {:ok, open(state)}
  end

  @impl GenServer
  def handle_call({:request, _request}, _from, %{port: nil} = state),
    do: {:reply, {:error, state.down}, state}

  def handle_call({:request, request}, from, state) do
    request = materialize(request)
    id = state.next_id

    if send_frame(state.port, Protocol.encode(id, request)) do
      timer = Process.send_after(self(), {:timeout, id}, state.timeout)
      pending = Map.put(state.pending, id, {from, timer, Protocol.kind(request)})
      {:noreply, %{state | pending: pending, next_id: next_id(id)}}
    else
      error = unavailable_error("key store program exited")
      GenServer.reply(from, {:error, error})
      restart(state, error)
    end
  end

  defp send_frame(port, frame) do
    Port.command(port, frame)
  catch
    :error, :badarg -> false
  end

  @impl GenServer
  def handle_info({port, {:data, frame}}, %{port: port} = state) do
    with {:ok, id, status, fields} <- Protocol.decode(frame),
         {{from, timer, kind}, pending} <- Map.pop(state.pending, id) do
      Process.cancel_timer(timer)
      GenServer.reply(from, Protocol.result(kind, status, fields))
      {:noreply, %{state | pending: pending, backoff: state.min_backoff}}
    else
      {nil, _pending} ->
        {:noreply, state}

      {:error, error} ->
        restart(state, error)
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("key store program exited", exit_status: status)
    restart(%{state | port: nil}, unavailable_error("key store program exited"))
  end

  def handle_info({:timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, _timer, _kind}, pending} ->
        GenServer.reply(
          from,
          {:error, Error.new(:key_store_timeout, "key store request timed out")}
        )

        Logger.warning("key store request timed out; restarting the program")
        restart(%{state | pending: pending}, unavailable_error("key store program restarted"))
    end
  end

  def handle_info(:reopen, %{port: nil} = state), do: {:noreply, open(state)}
  def handle_info(_message, state), do: {:noreply, state}

  # T-46
  @impl GenServer
  def format_status(status) do
    Relay.Hygiene.format_status(status, fn
      %{pending: pending} = state -> %{state | pending: map_size(pending), args: :redacted}
      other -> other
    end)
  end

  @impl GenServer
  def terminate(_reason, state) do
    close(state.port)
    :ok
  end

  defp materialize({:wrap, label, aad, data_key}), do: {:wrap, label, aad, data_key.()}
  defp materialize({:hmac, label, message}), do: {:hmac, label, message.()}
  defp materialize(request), do: request

  defp restart(state, error) do
    close(state.port)

    for {_id, {from, timer, _kind}} <- state.pending do
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, error})
    end

    Process.send_after(self(), :reopen, state.backoff)
    backoff = min(state.backoff * 2, state.max_backoff)
    {:noreply, %{state | port: nil, pending: %{}, down: error, backoff: backoff}}
  end

  defp open(state) do
    case verify(state.executable, state.sha256) do
      :ok ->
        port =
          Port.open({:spawn_executable, state.executable}, [
            :binary,
            :exit_status,
            :use_stdio,
            :hide,
            {:packet, 4},
            {:args, state.args}
          ])

        %{state | port: port}

      {:error, error} ->
        Logger.error("key store program failed verification", code: error.code)
        Process.send_after(self(), :reopen, state.backoff)
        %{state | down: error, backoff: min(state.backoff * 2, state.max_backoff)}
    end
  end

  # T-53
  # T-62
  # TN-65 (7)
  defp verify(_executable, nil),
    do: {:error, integrity_error("key store program has no embedded checksum")}

  # sobelow_skip ["Traversal.FileModule"]
  defp verify(executable, expected) do
    case File.read(executable) do
      {:ok, binary} ->
        actual = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

        if String.downcase(expected) == actual,
          do: :ok,
          else: {:error, integrity_error("key store program checksum does not match")}

      {:error, _} ->
        {:error, integrity_error("key store program is missing")}
    end
  end

  defp bundled_program, do: Application.app_dir(:relay, @program)

  defp close(nil), do: :ok

  defp close(port) do
    Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp args(opts) do
    [
      "--module",
      Keyword.fetch!(opts, :module),
      "--token",
      Keyword.fetch!(opts, :token),
      "--pin-file",
      Keyword.fetch!(opts, :pin_file)
    ]
  end

  defp next_id(@max_id), do: 1
  defp next_id(id), do: id + 1

  defp unavailable(message), do: {:error, unavailable_error(message)}
  defp unavailable_error(message), do: Error.new(:key_store_unavailable, message)
  defp integrity_error(message), do: Error.new(:key_store_integrity, message)
end
