defmodule Relay.Channels.Push.ApnsTokenTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.Apns.Credentials
  alias Relay.Channels.Push.Apns.Token
  alias Relay.Channels.Push.Jwt

  @now 1_793_836_800
  @minute 60

  defp down do
    error = Relay.Error.new(:key_store_token, "x")
    fn _alg, _label, _message -> {:error, error} end
  end

  defp alarm do
    parent = self()
    fn error, team, key -> send(parent, {:alarm, error.code, team, key}) end
  end

  defp header(token) do
    [head | _] = String.split(token, ".")
    {:ok, json} = Jwt.decode64(head)
    Jason.decode!(json)
  end

  describe "CH-25 provider token" do
    test "CH-25: the token is ES256 with kid, iss and iat, and verifies" do
      state = Token.new("TEAM123456", "KEY1234567", "apns-team-key")
      assert {:ok, token, state} = Token.current(state, @now)

      assert header(token) == %{"alg" => "ES256", "kid" => "KEY1234567"}
      assert Jwt.peek_claims(token) == {:ok, %{"iss" => "TEAM123456", "iat" => @now}}

      [h, c, signature] = String.split(token, ".")
      {:ok, <<sig_r::256, sig_s::256>>} = Jwt.decode64(signature)
      {:ok, public} = Relay.Keys.public_key(:es256, "apns-team-key")
      der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", sig_r, sig_s})
      assert :crypto.verify(:ecdsa, :sha256, h <> "." <> c, der, [public, :secp256r1])
      assert state.issued_at == @now
    end

    test "TN-29: the token is reused before 40 minutes and renewed at 40" do
      state = Token.new("T", "K", "apns-team-key")
      {:ok, first, state} = Token.current(state, @now)
      {:ok, same, state} = Token.current(state, @now + 39 * @minute)
      assert same == first

      {:ok, renewed, state} = Token.current(state, @now + 40 * @minute)
      assert renewed != first
      assert state.issued_at == @now + 40 * @minute
    end

    test "TN-29: the renewal age is configurable only between 20 and 60 minutes" do
      assert %Token{refresh_after: 1200} = Token.new("T", "K", "l", refresh_after: 1200)
      assert_raise ArgumentError, fn -> Token.new("T", "K", "l", refresh_after: 1199) end
      assert_raise ArgumentError, fn -> Token.new("T", "K", "l", refresh_after: 3601) end
    end

    test "CH-25: a forced refresh is refused within 20 minutes of the last token" do
      {:ok, _token, state} = Token.current(Token.new("T", "K", "apns-team-key"), @now)

      assert {:error, %{code: :apns_token_refresh_too_soon}, ^state} =
               Token.refresh(state, @now + 19 * @minute)

      assert {:ok, _new, %Token{issued_at: at}} = Token.refresh(state, @now + 20 * @minute)
      assert at == @now + 20 * @minute
    end
  end

  describe "TN-29 key store outage" do
    test "TN-29: the last good token serves while younger than an hour and the alarm fires" do
      {:ok, good, state} = Token.current(Token.new("T", "K", "apns-team-key"), @now)
      opts = [signer: down(), alarm: alarm()]

      assert {:degraded, ^good, ^state, %{code: :key_store_token}} =
               Token.current(state, @now + 45 * @minute, opts)

      assert_received {:alarm, :key_store_token, "T", "K"}

      assert {:error, %{code: :apns_token_unavailable}, ^state} =
               Token.current(state, @now + 60 * @minute, opts)

      assert_received {:alarm, :key_store_token, "T", "K"}
      refute Token.valid?(state, @now + 60 * @minute)
    end

    test "TN-29: without a last good token an outage is an error" do
      state = Token.new("T", "K", "apns-team-key")

      assert {:error, %{code: :apns_token_unavailable}, ^state} =
               Token.current(state, @now, signer: down(), alarm: alarm())

      assert_received {:alarm, :key_store_token, "T", "K"}
    end

    test "TN-29: the default alarm is a telemetry event" do
      ref = make_ref()
      parent = self()
      event = [:relay, :push, :signing_unavailable]

      :telemetry.attach(
        {__MODULE__, ref},
        event,
        fn ^event, measurements, metadata, _config ->
          send(parent, {:event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      Token.current(Token.new("T", "K-telemetry", "apns-team-key"), @now, signer: down())

      assert_received {:event, %{count: 1}, metadata}
      assert %{provider: :apns, key_id: "K-telemetry", code: :key_store_token} = metadata
    end
  end

  describe "TN-29 rotation with two keys" do
    test "TN-29: standby, promote, verify and retire without dropping the old key early" do
      c = Credentials.new("T", "OLD", "apns-old")
      assert {:ok, "OLD", old_token, c} = Credentials.token(c, @now)

      assert {:ok, c} = Credentials.add_standby(c, "NEW", "apns-new")
      assert {:error, %{code: :apns_key_exists}} = Credentials.add_standby(c, "NEW", "apns-new")
      assert {:ok, "OLD", ^old_token, c} = Credentials.token(c, @now + @minute)

      assert {:ok, c} = Credentials.promote(c, "NEW")
      assert {:ok, "NEW", new_token, c} = Credentials.token(c, @now + 2 * @minute)
      assert header(new_token)["kid"] == "NEW"

      assert {:error, %{code: :apns_key_active}} = Credentials.retire(c, "NEW")
      assert {:ok, c} = Credentials.retire(c, "OLD")
      assert {:error, %{code: :apns_key_unknown}} = Credentials.promote(c, "OLD")
    end

    test "TN-29: an outage on the active key reports degraded with the last good token" do
      c = Credentials.new("T", "K", "apns-team-key")
      {:ok, "K", token, c} = Credentials.token(c, @now)
      opts = [signer: down(), alarm: alarm()]
      assert {:degraded, "K", ^token, _c} = Credentials.token(c, @now + 50 * @minute, opts)
    end
  end
end
