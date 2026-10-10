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

  test "T-3: nodes with the api or socket role serve HTTP; worker-only nodes do not" do
    runtime = File.read!("config/runtime.exs")
    assert runtime =~ "server: :api in roles or :socket in roles"
  end
end
