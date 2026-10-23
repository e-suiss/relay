defmodule Relay.SecretFilesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Relay.Config.SecretFiles
  alias Relay.Redacted

  @moduletag :tmp_dir

  @secrets %{
    "DATABASE_PASSWORD_FILE" => "plain-db-marker",
    "MAINT_DATABASE_PASSWORD_FILE" => "plain-maint-marker",
    "QUEUE_DATABASE_PASSWORD_FILE" => "plain-queue-marker",
    "AUDIT_S3_SECRET_ACCESS_KEY_FILE" => "plain-store-marker"
  }

  @env %{
    "DATABASE_URL" => "ecto://relay_worker@db.internal:5432/relay",
    "MAINT_DATABASE_URL" => "ecto://relay_maint@db.internal:5432/relay",
    "QUEUE_DATABASE_URL" => "ecto://relay_queue@db.internal:5432/relay",
    "POOL_SIZE" => "5",
    "PKCS11_MODULE" => "/usr/lib/softhsm/libsofthsm2.so",
    "PKCS11_TOKEN" => "relay",
    "PKCS11_PIN_FILE" => "/run/softhsm/pin",
    "KEY_STORE_KEK_LABEL" => "kek",
    "KEY_STORE_FINGERPRINT_LABEL" => "fingerprint",
    "RELAY_HOST" => "relay.example.com",
    "AUDIT_S3_ENDPOINT" => "https://s3.example.com",
    "AUDIT_S3_BUCKET" => "relay-audit",
    "AUDIT_S3_REGION" => "eu-central-1",
    "AUDIT_S3_ACCESS_KEY_ID" => "relay",
    "VALKEY_URL" => "redis://valkey.internal:6379",
    "PORT" => "4000",
    "METRICS_PORT" => "9568",
    "SECRET_KEY_BASE" => String.duplicate("k", 64),
    "RELAY_ROLES" => "api,worker,socket"
  }

  defp secret_files(dir) do
    Map.new(@secrets, fn {name, secret} ->
      path = Path.join(dir, String.downcase(name))
      File.write!(path, secret <> "\n")
      {name, path}
    end)
  end

  defp with_env(env, fun) do
    previous = Map.new(env, fn {name, _} -> {name, System.get_env(name)} end)
    System.put_env(env)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  defp production_env(dir) do
    with_env(Map.merge(@env, secret_files(dir)), fn ->
      base = Config.Reader.read!("config/config.exs", env: :prod)
      runtime = Config.Reader.read!("config/runtime.exs", env: :prod)
      base |> Config.Reader.merge(runtime) |> Keyword.fetch!(:relay)
    end)
  end

  defp shows_secret?(term) do
    text = inspect(term, limit: :infinity, printable_limit: :infinity, structs: false)
    Enum.any?(@secrets, fn {_name, secret} -> text =~ secret end)
  end

  defp with_paths(paths, fun) do
    previous = :sys.replace_state(SecretFiles, fn _ -> paths end)

    try do
      fun.()
    after
      :sys.replace_state(SecretFiles, fn _ -> previous end)
    end
  end

  describe "TN-67 (3) installation secrets stay out of the application environment" do
    test "TN-67: the production environment holds the secret file paths, never a database password or the object store key",
         %{tmp_dir: dir} do
      env = production_env(dir)

      refute shows_secret?(env)

      for repo <- [Relay.Repo, Relay.QueueRepo, Relay.Platform.MaintRepo] do
        refute Keyword.has_key?(env[repo], :password), inspect(repo)
        assert {SecretFiles, :configure, [_name]} = env[repo][:configure]
      end

      assert [{"worm_store", _, opts}] = env[Relay.Audit][:publishers]
      assert opts[:secret_access_key] == {SecretFiles, :fetch!, [:audit_s3]}

      assert Enum.sort(Keyword.keys(env[SecretFiles])) == Enum.sort(SecretFiles.names())
      assert :ok = Relay.Config.validate!(env, %{}, production?: true)
    end

    test "TN-67: a production node refuses a plain database password or object store key", %{
      tmp_dir: dir
    } do
      env = production_env(dir)

      assert_raise Relay.Config.Error, ~r/Relay.Repo must take its password/, fn ->
        env
        |> Keyword.update!(Relay.Repo, &Keyword.put(&1, :password, "plain"))
        |> Relay.Config.validate!(%{}, production?: true)
      end

      [{target, module, opts}] = env[Relay.Audit][:publishers]
      plain = [{target, module, Keyword.put(opts, :secret_access_key, Redacted.wrap("plain"))}]

      assert_raise Relay.Config.Error, ~r/worm_store must take its secret/, fn ->
        env
        |> Keyword.update!(Relay.Audit, &Keyword.put(&1, :publishers, plain))
        |> Relay.Config.validate!(%{}, production?: true)
      end
    end

    test "TN-67: a database connection reads its password through the sensitive holder", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "db")
      File.write!(path, "plain-db-marker\n")

      with_paths(%{repo: path}, fn ->
        opts = SecretFiles.configure([username: "relay_worker"], :repo)
        assert opts[:password] == "plain-db-marker"
        assert Process.info(self(), :dictionary) == {:dictionary, []}

        File.write!(path, "rotated-secret\n")
        assert {:ok, rotated} = SecretFiles.fetch(:repo)
        assert Redacted.expose(rotated) == "rotated-secret"

        assert {:error, %Relay.Error{code: :secret_unavailable}} = SecretFiles.fetch(:audit_s3)
      end)
    end
  end

  describe "T-46 TN-67 (3) the secret holder process" do
    test "T-46: the holder is sensitive and neither its state nor its status shows a secret", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "s3")
      File.write!(path, "plain-store-marker")
      pid = Process.whereis(SecretFiles)

      with_paths(%{audit_s3: path}, fn ->
        assert {:ok, secret} = SecretFiles.fetch(:audit_s3)
        assert Redacted.expose(secret) == "plain-store-marker"
        refute shows_secret?(:sys.get_status(pid))
        refute shows_secret?(:sys.get_state(pid))
      end)

      assert Process.info(pid, :dictionary) == {:dictionary, []}
    end

    test "T-46: a crash report of the holder shows neither the secret nor the message that crashed it",
         %{tmp_dir: dir} do
      path = Path.join(dir, "s3")
      File.write!(path, "plain-store-marker")
      {:ok, pid} = GenServer.start(SecretFiles, audit_s3: path)

      log =
        capture_log(fn ->
          ref = Process.monitor(pid)
          catch_exit(GenServer.call(pid, {:leak, "plain-store-marker"}))
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
          Logger.flush()
        end)

      assert log =~ "Relay.Config.SecretFiles"
      refute log =~ "plain-store-marker"
    end

    test "TN-67: a missing or empty secret file stops the holder at startup", %{tmp_dir: dir} do
      empty = Path.join(dir, "empty")
      File.write!(empty, "\n")
      Process.flag(:trap_exit, true)

      assert {:error, {:unreadable_secret_file, :repo}} =
               GenServer.start_link(SecretFiles, repo: Path.join(dir, "missing"))

      assert {:error, {:unreadable_secret_file, :repo}} =
               GenServer.start_link(SecretFiles, repo: empty)

      assert {:error, {:invalid_secret_file, :unknown}} =
               GenServer.start_link(SecretFiles, unknown: empty)
    end
  end

  describe "T-46 TN-67 (3) audit task processes" do
    test "TN-67: the audit tasks run in sensitive runners whose status is redacted" do
      tasks = Application.fetch_env!(:relay, Relay.Platform.Leadership)[:tasks]

      for {name, _module, opts} <- tasks,
          name in ["audit_checkpoint", "audit_verify", "audit_readback"],
          do: assert(opts[:sensitive] == true, name)

      status =
        Relay.Platform.Leadership.Runner.format_status(%{
          state: %{sensitive: true, saved: %{"cursor" => "plain-store-marker"}, name: "audit"},
          message: {:tick, "plain-store-marker"},
          reason: {%MatchError{term: "plain-store-marker"}, [{M, :f, ["plain-store-marker"], []}]}
        })

      refute shows_secret?(status)
      assert status.state.name == "audit"
    end
  end
end
