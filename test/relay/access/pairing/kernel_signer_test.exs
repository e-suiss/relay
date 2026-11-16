defmodule Relay.Access.Pairing.KernelSignerTest do
  use ExUnit.Case, async: false

  alias Relay.Access.Pairing.KernelSigner
  alias Relay.Access.ServiceKey
  alias Relay.Error
  alias RelayTest.AccessKernel

  @now 1_794_000_060_000
  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @key Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @vector %{
    domain: :binary.copy(<<0x22>>, 32),
    basis: Base.decode16!("DBC752A072AF3666687FF3843115056D"),
    pep: "access-identity",
    party: :binary.copy(<<0x11>>, 16),
    kid: Base.decode16!("90FACAFEA9B1556698540F70C0117A22EA37BD5CF3ED3C47093C1707282B4B89"),
    challenge: :binary.copy(<<0x33>>, 32),
    valid_from_ms: 1_794_000_000_000,
    valid_until_ms: 1_794_000_600_000,
    now_ms: @now,
    instance_create: %{
      nonce: :binary.copy(<<0x33>>, 32),
      intent: Base.decode16!("9F402BC9C95A8F212916DCE044A03BB8F8E12227C531A4E8E2DCB13FC9661BBF")
    },
    party_register: %{
      nonce: :binary.copy(<<0x33>>, 32) <> <<1>>,
      intent: Base.decode16!("8BD4510B2870DCA8A2DF9876DC12F333BB08C9E0755BE7844026C1357DF53278")
    }
  }
  @ais """
  d2845844a3013203781b6170706c69636174696f6e2f6163636573732d6169732b63626f72
  04582090facafea9b1556698540f70c0117a22ea37bd5cf3ed3c47093c1707282b4b89a058
  d8a8636961741b000001a1b2bc7e60637065706f6163636573732d6964656e74697479646d
  6f646566636f6d6d6974656261736973a1667075626c696350dbc752a072af3666687ff384
  3115056d656e6f6e6365582033333333333333333333333333333333333333333333333333
  3333333333333366646f6d61696e822f582022222222222222222222222222222222222222
  2222222222222222222222222266696e74656e74822f58209f402bc9c95a8f212916dce044
  a03bb8f8e12227c531a4e8e2dcb13fc9661bbf686361706163697479636f776e584015068c
  0f5dc9e8840b3b07119ddadcf129124093aa6f5d6966d5ba51d356b4497906edccfec60cca
  b51f664e0c59aadb8d3eb9fac9596ef4fd5992b0f9eab201
  """
  @register_ais """
  d2845844a3013203781b6170706c69636174696f6e2f6163636573732d6169732b63626f72
  04582090facafea9b1556698540f70c0117a22ea37bd5cf3ed3c47093c1707282b4b89a058
  d9a8636961741b000001a1b2bc7e60637065706f6163636573732d6964656e74697479646d
  6f646566636f6d6d6974656261736973a1667075626c696350dbc752a072af3666687ff384
  3115056d656e6f6e6365582133333333333333333333333333333333333333333333333333
  333333333333330166646f6d61696e822f5820222222222222222222222222222222222222
  222222222222222222222222222266696e74656e74822f58208bd4510b2870dca8a2df9876
  dc12f333bb08c9e0755be7844026c1357df53278686361706163697479636f776e5840848f
  747b875ca2372303630ea5994191bb3c0b0d7dff84c7f6e94a87a2f8a91ab0322044b3d4e4
  63efe7037fea504ea4b10e8252975f908e0791fb3c220cd305
  """

  defmodule Keys do
    @moduledoc false

    def sign_pairing(label, pairing) do
      send(self(), {:sign_pairing, label, pairing})
      Process.get(__MODULE__)
    end
  end

  defp hex(text), do: text |> String.replace("\n", "") |> Base.decode16!(case: :lower)

  defp service_key do
    {:ok, key} = Relay.Keys.public_key(:ed25519, ServiceKey.label())
    key
  end

  defp answer(result), do: Process.put(Keys, result)

  describe "E-101 the wire format of a known challenge" do
    test "E-101: the bootstrap Grant and the intent digests are those of the key store port" do
      window = {@vector.valid_from_ms, @vector.valid_until_ms}

      assert AccessKernel.thumbprint(@key) == @vector.kid
      assert AccessKernel.bootstrap_basis(@vector.domain) == @vector.basis

      assert AccessKernel.intent(:instance_create, @vector.party, @key, window) ==
               @vector.instance_create.intent

      assert AccessKernel.intent(:party_register, @vector.party, @key, window) ==
               @vector.party_register.intent
    end

    test "E-101: the signed statements are those of the key store port" do
      sign = fn message -> :crypto.sign(:eddsa, :none, message, [@seed, :ed25519]) end

      assert AccessKernel.sign_pairing(@vector, @key, sign) ==
               {:ok, [hex(@ais), hex(@register_ais)]}

      statement = AccessKernel.statement(@vector, @vector.instance_create)
      assert AccessKernel.signed?(hex(@ais), statement, @vector.kid, @key)
      refute AccessKernel.signed?(hex(@register_ais), statement, @vector.kid, @key)
    end
  end

  describe "E-101 signing through the key store" do
    test "E-101: both statements are signed as COSE_Sign1 and verify under the service public key" do
      key = service_key()
      target = AccessKernel.target(key, @now)
      pairing = Map.put(target, :now_ms, @now)

      assert {:ok, %{ais: ais, register_ais: register_ais}} = KernelSigner.sign(target, key, @now)

      create = AccessKernel.statement(pairing, target.instance_create)
      register = AccessKernel.statement(pairing, target.party_register)
      assert AccessKernel.signed?(ais, create, target.kid, key)
      assert AccessKernel.signed?(register_ais, register, target.kid, key)
      refute AccessKernel.signed?(ais, register, target.kid, key)
    end

    test "E-101: a target without a registration gets only the instance statement" do
      key = service_key()
      target = AccessKernel.target(key, @now, party_register: false)

      assert {:ok, %{ais: ais, register_ais: nil}} = KernelSigner.sign(target, key, @now)

      statement = AccessKernel.statement(Map.put(target, :now_ms, @now), target.instance_create)
      assert AccessKernel.signed?(ais, statement, target.kid, key)
    end

    test "E-101: a wrong kid, nonce, window, basis or intent digest is refused with its code" do
      key = service_key()

      for {code, tampered} <- AccessKernel.tampered(AccessKernel.target(key, @now)) do
        assert {code, KernelSigner.sign(tampered, key, @now)} ==
                 {code, {:error, {:unsignable, code}}}
      end
    end

    test "E-101: less than 60 seconds of validity is refused" do
      key = service_key()
      target = AccessKernel.target(key, @now)

      assert KernelSigner.sign(target, key, target.valid_until_ms - 59_999) ==
               {:error, {:unsignable, "pairing-validity"}}

      assert {:ok, _signed} = KernelSigner.sign(target, key, target.valid_until_ms - 60_000)
    end
  end

  describe "E-101 the request to the key store" do
    setup do
      keys = Application.fetch_env!(:relay, :keys)
      Application.put_env(:relay, :keys, Keys)
      on_exit(fn -> Application.put_env(:relay, :keys, keys) end)
    end

    test "E-101: the key store gets the target and the signing time under the service key label" do
      target = AccessKernel.target(@key, @now)
      answer({:ok, ["ais", "register-ais"]})

      assert KernelSigner.sign(target, @key, @now) ==
               {:ok, %{ais: "ais", register_ais: "register-ais"}}

      assert_received {:sign_pairing, "access-service", pairing}
      assert pairing == target |> Map.drop([:status, :realm]) |> Map.put(:now_ms, @now)
    end

    test "E-101: a refusal of the key store names the check and any other failure is its error" do
      target = AccessKernel.target(@key, @now)
      refused = Error.new(:key_refused, "key store: refused: x", %{reason: "pairing-signature"})
      answer({:error, refused})
      assert KernelSigner.sign(target, @key, @now) == {:error, {:unsignable, "pairing-signature"}}

      down = Error.new(:key_store_unavailable, "key store program exited")
      answer({:error, down})
      assert KernelSigner.sign(target, @key, @now) == {:error, down}
    end

    test "E-101: an answer that does not fit the target is not taken" do
      target = AccessKernel.target(@key, @now)
      answer({:ok, ["ais"]})
      assert KernelSigner.sign(target, @key, @now) == {:error, {:unsignable, "pairing-encoding"}}

      single = AccessKernel.target(@key, @now, party_register: false)
      answer({:ok, ["ais", "register-ais"]})
      assert KernelSigner.sign(single, @key, @now) == {:error, {:unsignable, "pairing-encoding"}}
    end

    test "E-101: a time the key store cannot carry is refused before it is asked" do
      target = AccessKernel.target(@key, @now)
      answer({:ok, ["ais", "register-ais"]})

      late = %{target | valid_until_ms: 0x1_0000_0000_0000_0000}

      for bad <- [%{target | valid_from_ms: -1}, late] do
        assert KernelSigner.sign(bad, @key, @now) == {:error, {:unsignable, "pairing-validity"}}
      end

      assert KernelSigner.sign(target, @key, -1) == {:error, {:unsignable, "pairing-validity"}}
      refute_received {:sign_pairing, _label, _pairing}
    end
  end
end
