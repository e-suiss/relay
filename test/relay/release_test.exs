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
