defmodule Relay.Channels.DeclarationsTest do
  use ExUnit.Case, async: true

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Registry
  alias Relay.Datasets.Package

  @moduletag :tmp_dir

  @channels ~w(push web_push email sms voice whatsapp slack teams telegram discord in_app webhook)

  defp bundled do
    {:ok, content} = ChannelDeclarations.compose()
    content
  end

  defp snapshot(content \\ bundled()), do: ChannelDeclarations.new(content, nil)

  defp fake_declaration(content \\ bundled()),
    do: Enum.find(content["providers"], &(&1["provider"] == "fake"))

  defp with_fake(fun) do
    content = bundled()
    providers = Enum.map(content["providers"], &replace(&1, fun))
    snapshot(%{content | "providers" => providers})
  end

  defp replace(%{"provider" => "fake"} = declaration, fun), do: fun.(declaration)
  defp replace(declaration, _fun), do: declaration

  describe "CH-71 DS-11 activation gate" do
    test "CH-71, DS-11, CH-2: every registered adapter passes the activation gate against the repository declarations" do
      declarations = snapshot()

      for adapter <- Registry.adapters() do
        assert Registry.check(declarations, adapter) == :ok, inspect(adapter)
        assert {:ok, ^adapter} = Registry.activated(declarations, adapter.provider())
      end

      assert Enum.all?(Registry.status(declarations), & &1.activated)
    end

    test "DS-11: every test vector of every registered adapter matches its mapping and its own decoding" do
      declarations = snapshot()

      for adapter <- Registry.adapters() do
        {:ok, declaration} = ChannelDeclarations.declaration(declarations, adapter.provider())
        assert declaration["vectors"] != []

        for vector <- declaration["vectors"] do
          code = vector["raw"]["code"]

          expected = ChannelDeclarations.expectation(declarations, adapter.provider(), code)
          assert expected == vector["expect"], "#{adapter.provider()} #{vector["name"]}"

          if Map.has_key?(vector, "response") and function_exported?(adapter, :decode, 1) do
            assert adapter.decode(vector["response"]).code == code
          end
        end

        mapped = MapSet.new(declaration["errors"], & &1["code"])
        covered = MapSet.new(declaration["vectors"], & &1["raw"]["code"])
        assert MapSet.subset?(mapped, covered), adapter.provider()
      end
    end

    test "CH-2, C-44: an adapter whose declaration is incomplete is registered but not activated" do
      declarations =
        with_fake(fn declaration ->
          declaration
          |> Map.delete("provider_idempotency_policy")
          |> Map.put("vectors", tl(declaration["vectors"]))
        end)

      assert {:error, missing} = Registry.check(declarations, Relay.Channels.Fake)
      assert :provider_idempotency_policy in missing
      assert :test_vectors in missing
      assert {:error, :not_activated} = Registry.activated(declarations, "fake")
      status = Enum.find(Registry.status(declarations), &(&1.provider == "fake"))
      assert %{activated: false} = status

      assert {:error, [:declaration, :channels]} =
               Registry.check(snapshot(%{bundled() | "providers" => []}), Relay.Channels.Fake)
    end

    test "INV-13, T-28: an adapter without an idempotency policy, or waiting without a status query, is not activated" do
      waiting = with_fake(&put_in(&1, ["provider_idempotency_policy", "status_query"], false))

      assert {:error, [:provider_idempotency_policy]} =
               ChannelDeclarations.gate(waiting, "fake")
    end

    test "CH-6, TN-58: data residency needs a transfer basis and the clause date under standard contractual clauses" do
      abroad =
        with_fake(fn declaration ->
          Map.put(declaration, "data_residency", %{
            "in_installation" => false,
            "processing_countries" => ["US"],
            "transfer_basis" => "scc",
            "scc_notified_on" => nil,
            "source" => "test"
          })
        end)

      assert {:error, [:data_residency]} = ChannelDeclarations.gate(abroad, "fake")

      {:ok, declaration} = ChannelDeclarations.declaration(abroad, "fake")
      refute ChannelDeclarations.domestic?(declaration, "TR")
      assert ChannelDeclarations.domestic?(fake_declaration(), "TR")

      domestic = put_in(declaration, ["data_residency", "processing_countries"], ["TR"])
      assert ChannelDeclarations.domestic?(domestic, "TR")
      refute ChannelDeclarations.domestic?(domestic, "DE")
    end

    test "CH-3, T-40: a compensating inbound control must be declared unverifiable and none needs no inbound channel" do
      token =
        with_fake(fn declaration ->
          Map.put(declaration, "inbound_verification", %{
            "method" => "secret_token",
            "header" => "x-token",
            "authenticity" => "verified",
            "source" => "test"
          })
        end)

      assert {:error, [:inbound_verification]} = ChannelDeclarations.gate(token, "fake")

      inbound = with_fake(&put_in(&1, ["capabilities", "sms", "inbound"], true))

      assert {:error, [:inbound_verification]} = ChannelDeclarations.gate(inbound, "fake")
    end
  end

  describe "DS-10 DS-12 evidence and delivery semantics" do
    test "DS-10: an event code without an evidence row is rejected" do
      declarations = snapshot()

      assert {:ok, %{"sets_delivery" => "accepted"}} =
               ChannelDeclarations.evidence(declarations, "fake", "sms", "accepted")

      assert {:error, :unknown_event} =
               ChannelDeclarations.evidence(declarations, "fake", "sms", "opened")

      assert {:error, :unknown_event} =
               ChannelDeclarations.evidence(declarations, "fake", "in_app", "accepted")
    end

    test "DS-10: the evidence rows of a mapped event code are required by the gate" do
      declarations =
        with_fake(fn declaration ->
          evidence = Enum.reject(declaration["evidence"], &(&1["event_code"] == "unregistered"))
          Map.put(declaration, "evidence", evidence)
        end)

      assert {:error, [:evidence]} = ChannelDeclarations.gate(declarations, "fake")
    end

    test "DS-12, INV-5: every channel has a delivery semantics row and a channel without one is not activated" do
      declarations = snapshot()

      for channel <- @channels do
        assert {:ok, %{"delivered" => delivered}} =
                 ChannelDeclarations.semantics(declarations, channel)

        assert is_binary(delivered)
      end

      {:ok, %{"decision_signals" => push}} = ChannelDeclarations.semantics(declarations, "push")
      refute "accepted" in push

      content = bundled()
      semantics = Enum.reject(content["semantics"], &(&1["channel"] == "voice"))
      missing = snapshot(%{content | "semantics" => semantics})

      assert {:error, [:semantics]} = ChannelDeclarations.gate(missing, "fake")
    end
  end

  describe "CH-71 OP-65 versioned data" do
    test "CH-71, OP-65: the declarations are one generated version of the channel_event_evidence data set" do
      assert {:ok, datasets} = Package.read(Package.root())
      assert %{versions: [version]} = Enum.find(datasets, &(&1.name == "channel_event_evidence"))
      assert version.content == bundled()
      assert "sha256:" <> hex = version.ref
      assert byte_size(hex) == 16
    end

    test "CH-71: the consistency rules refuse duplicate rows and foreign channels" do
      content = bundled()
      fake = fake_declaration(content)

      duplicate = %{content | "providers" => [fake, fake]}

      assert {:error, %Relay.Error{details: %{rule: :unique_providers}}} =
               ChannelDeclarations.validate(duplicate)

      row = %{hd(fake["evidence"]) | "channel" => "in_app"}
      foreign = %{content | "providers" => [%{fake | "evidence" => [row | fake["evidence"]]}]}

      assert {:error, %Relay.Error{details: %{rule: :evidence_channels}}} =
               ChannelDeclarations.validate(foreign)

      codes = %{fake | "errors" => [hd(fake["errors"]) | fake["errors"]]}

      assert {:error, %Relay.Error{details: %{rule: :unique_codes}}} =
               ChannelDeclarations.validate(%{content | "providers" => [codes]})

      assert ChannelDeclarations.validate(content) == :ok
    end

    test "CH-71: a provider directory holds only its declaration files and is named after its provider", %{
      tmp_dir: dir
    } do
      File.cp_r!(ChannelDeclarations.root(), dir)
      assert {:ok, _content} = ChannelDeclarations.compose(dir)

      File.write!(Path.join([dir, "fake", "notes.txt"]), "")
      assert {:error, %Relay.Error{code: :invalid_package}} = ChannelDeclarations.compose(dir)
      File.rm!(Path.join([dir, "fake", "notes.txt"]))

      File.cp_r!(Path.join(dir, "fake"), Path.join(dir, "other"))
      assert {:error, %Relay.Error{code: :invalid_package}} = ChannelDeclarations.compose(dir)
      File.rm_rf!(Path.join(dir, "other"))

      File.rm!(Path.join([dir, "fake", "vectors.json"]))
      assert {:ok, content} = ChannelDeclarations.compose(dir)
      assert {:error, missing} = ChannelDeclarations.gate(snapshot(content), "fake")
      assert :test_vectors in missing
    end
  end
end
