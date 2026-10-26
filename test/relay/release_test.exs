defmodule Relay.ReleaseTest do
  use ExUnit.Case, async: true

  test "T-13: releases run with Erlang distribution off" do
    assert File.read!("rel/env.sh.eex") =~ ~r/^export RELEASE_DISTRIBUTION=none$/m
  end

  test "T-46: releases never write crash dumps" do
    env = File.read!("rel/env.sh.eex")
    assert env =~ ~r/^export ERL_CRASH_DUMP_BYTES=0$/m
  end

  test "T-5: nodes never migrate on boot; migration is a separate release command" do
    application = File.read!("lib/relay/application.ex")
    refute application =~ "Migrator"
    assert function_exported?(Code.ensure_loaded!(Relay.Release), :migrate, 0)
  end

  describe "OP-69 post-migration bootstrap" do
    test "OP-69: the bootstrap is a separate release command run as the installation administrator" do
      assert function_exported?(Code.ensure_loaded!(Relay.Release), :bootstrap, 0)
      assert File.exists?(Relay.Release.bootstrap_script())
      assert File.read!("lib/relay/release.ex") =~ ~s("ADMIN_DATABASE_URL")
      assert File.read!("lib/relay/release.ex") =~ ~s("ADMIN_DATABASE_PASSWORD_FILE")
    end

    test "OP-69: the Helm migrate hook runs bootstrap, then the migration as relay_migrator, then the bootstrap again" do
      job = File.read!("deploy/helm/relay/templates/migrate-job.yaml")
      [init, main] = String.split(job, "      containers:\n")
      [before, migrate] = String.split(init, "        - name: migrate\n")
      assert before =~ ~s{include "relay.bootstrap-container" (dict "root" . "name" "bootstrap")}
      assert migrate =~ ~s{args: ["eval", "Relay.Release.migrate()"]}
      assert migrate =~ ".Values.database.migratorUrl"
      assert migrate =~ "/run/secrets/relay-migrator/password"
      assert migrate =~ ~s{include "relay.env.shared"}
      refute migrate =~ ~s{include "relay.env" }
      assert main =~ ~s{include "relay.bootstrap-container" (dict "root" . "name" "ownership")}

      helpers = File.read!("deploy/helm/relay/templates/_env.tpl")
      assert helpers =~ ~s{args: ["eval", "Relay.Release.bootstrap()"]}
      assert helpers =~ "ADMIN_DATABASE_URL"
    end

    test "OP-69: the smoke test bootstraps after migrating and sees a wrong owner stop the node" do
      smoke = File.read!("deploy/smoke.sh")
      [_, after_migrate] = String.split(smoke, "eval 'Relay.Release.migrate()'", parts: 2)
      assert after_migrate =~ ~r/^bootstrap \|\| fail "post-migration bootstrap failed"$/m
      assert after_migrate =~ "relay_ops ownership check failed"
    end

    test "OP-69: the bootstrap script hands every relay_ops function to relay_maint" do
      assert File.read!("priv/repo/bootstrap.sql") =~ "ALTER FUNCTION %s OWNER TO relay_maint"
    end

    test "OP-72 (2): the bootstrap grants EXECUTE on relay_ops functions exactly as the golden contract lists" do
      [_, listed] =
        Regex.run(
          ~r/v_execute constant jsonb := '(\{.*?\})';/s,
          File.read!("priv/repo/bootstrap.sql")
        )

      golden =
        for line <- String.split(File.read!("test/golden/db_functions.txt"), "\n"),
            String.starts_with?(line, "relay_ops."),
            [name | _] = String.split(line, "("),
            [_, execute] = Regex.run(~r/\| execute ([^|]*)/, line),
            into: %{},
            do: {name, execute |> String.trim() |> String.split(",", trim: true)}

      assert golden != %{}

      assert Map.new(Jason.decode!(listed), fn {name, roles} -> {name, Enum.sort(roles)} end) ==
               golden
    end

    test "OP-73: the bootstrap hands the relay_ops schema to relay_migrator" do
      bootstrap = File.read!("priv/repo/bootstrap.sql")
      assert bootstrap =~ "CREATE SCHEMA IF NOT EXISTS relay_ops AUTHORIZATION relay_migrator;"
      assert bootstrap =~ "ALTER SCHEMA relay_ops OWNER TO relay_migrator;"
    end

    test "OP-72 (2): relay_migrator is never granted relay_maint" do
      refute File.read!("priv/repo/bootstrap.sql") =~ ~r/GRANT\s+relay_maint\s+TO/i
    end
  end

  test "T-49: the release does not bundle SSH or inets" do
    release = Mix.Project.config()[:releases][:relay]
    apps = Keyword.keys(release[:applications] || [])
    refute :ssh in apps
    refute :inets in apps
    refute :ssh in Application.spec(:relay, :applications)
    refute :inets in Application.spec(:relay, :applications)
  end

  test "T-74: the package is published under the esuiss prefix" do
    assert Mix.Project.config()[:package][:name] == "esuiss_relay"
  end

  describe "TN-63 key store program in the image" do
    test "T-62: the image builds the program with the pinned toolchain from the lock file" do
      dockerfile = File.read!("deploy/docker/Dockerfile")

      [_, channel] =
        Regex.run(
          ~r/^channel = "([^"]+)"$/m,
          File.read!("native/pkcs11_port/rust-toolchain.toml")
        )

      assert dockerfile =~
               ~r/^FROM rust:#{Regex.escape(channel)}-\S+@sha256:[0-9a-f]{64} AS native$/m

      assert dockerfile =~ "cargo build --locked --release"
    end

    test "TN-65 (7): the image bundles the program and embeds its checksum before compiling" do
      dockerfile = File.read!("deploy/docker/Dockerfile")

      assert dockerfile =~
               "COPY --from=native /build/target/release/pkcs11_port priv/native/pkcs11_port"

      assert dockerfile =~
               "RUN sha256sum priv/native/pkcs11_port > priv/native/pkcs11_port.sha256"

      [checksum, compile] =
        for marker <- ["pkcs11_port.sha256", "mix compile"],
            do: :binary.match(dockerfile, marker) |> elem(0)

      assert checksum < compile
    end

    test "TN-63: the production image carries no PKCS#11 provider" do
      runtime =
        "deploy/docker/Dockerfile" |> File.read!() |> String.split(~r/^FROM /m) |> List.last()

      refute runtime =~ ~r/softhsm/i
    end
  end

  test "T-3: nodes with the api or socket role serve HTTP; worker-only nodes do not" do
    runtime = File.read!("config/runtime.exs")
    assert runtime =~ "server: :api in roles or :socket in roles"
  end
end
