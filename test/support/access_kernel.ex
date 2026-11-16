defmodule RelayTest.AccessKernel do
  @moduledoc """
  What Access computes for a pairing challenge (E-101), written from the wire format alone and independent of the Access kernel crate the key store port links: deterministic CBOR (RFC 8949 §4.2.1), the Genesis bootstrap Grant of a domain, the intent digests of the self-signed `instance_create` and `party_register` Exercises, the Actor Intent Statement and its tagged `COSE_Sign1`.

  `target/3` is an `unpaired` target as Access issues it for a service key, `tampered/1` lists targets that each fail one check with the code of that check, `sign_pairing/3` answers a challenge as the port program does, with the same checks in the same order (it is how `RelayTest.Keys` signs), and `signed?/4` tells whether a `COSE_Sign1` carries a statement under a key.
  """

  use Boundary, top_level?: true, deps: [], exports: []

  @content_type "application/access-ais+cbor"
  @min_validity_ms 60_000
  @realm "00000000-0000-4000-8000-00000000000a"

  @type cbor ::
          integer() | String.t() | {:bytes, binary()} | [cbor()] | %{optional(cbor()) => cbor()}
  @type exercise :: :instance_create | :party_register
  @type window :: {integer(), integer()}

  @doc "The deterministic CBOR of a value: integers, text, `{:bytes, binary}`, lists and maps, map keys in the bytewise order of their encodings."
  @spec encode(cbor()) :: binary()
  def encode(n) when is_integer(n) and n >= 0, do: head(0, n)
  def encode(n) when is_integer(n), do: head(1, -1 - n)
  def encode({:bytes, bytes}), do: head(2, byte_size(bytes)) <> bytes
  def encode(text) when is_binary(text), do: head(3, byte_size(text)) <> text

  def encode(list) when is_list(list),
    do: IO.iodata_to_binary([head(4, length(list)) | Enum.map(list, &encode/1)])

  def encode(map) when is_map(map) do
    entries = map |> Enum.map(fn {key, value} -> {encode(key), encode(value)} end) |> Enum.sort()
    IO.iodata_to_binary([head(5, length(entries)) | Enum.map(entries, &Tuple.to_list/1)])
  end

  defp head(major, n) when n < 24, do: <<major::3, n::5>>
  defp head(major, n) when n < 0x100, do: <<major::3, 24::5, n::8>>
  defp head(major, n) when n < 0x10000, do: <<major::3, 25::5, n::16>>
  defp head(major, n) when n < 0x100000000, do: <<major::3, 26::5, n::32>>
  defp head(major, n), do: <<major::3, 27::5, n::64>>

  defp context(label, bytes), do: :crypto.hash(:sha256, [label, 0, bytes])

  defp digest(hash), do: [-16, {:bytes, hash}]

  @doc "The RFC 7638 thumbprint of a 32-byte Ed25519 key."
  @spec thumbprint(<<_::256>>) :: <<_::256>>
  def thumbprint(<<_::256>> = key) do
    x = Base.url_encode64(key, padding: false)
    :crypto.hash(:sha256, ~s({"crv":"Ed25519","kty":"OKP","x":"#{x}"}))
  end

  @doc "The Genesis bootstrap Grant of a domain: the first `grant` object of the domain."
  @spec bootstrap_basis(<<_::256>>) :: <<_::128>>
  def bootstrap_basis(<<_::256>> = domain) do
    object = encode([digest(domain), "grant", 0])
    binary_part(context("access/object/v1", object), 0, 16)
  end

  @doc "The intent digest of the self-signed `exercise` of `party` under the key `key` over the validity window `{from_ms, until_ms}`."
  @spec intent(exercise(), <<_::128>>, <<_::256>>, window()) :: <<_::256>>
  def intent(exercise, <<_::128>> = party, <<_::256>> = key, {from_ms, until_ms}) do
    name = Atom.to_string(exercise)
    schema = %{"name" => name, "major" => 1, "effect_class" => "reversible"}
    schema_digest = context("access/action-schema/v1", encode(schema))
    payload = context("access/meta/v1", encode(%{name => payload(exercise, party, key)}))

    envelope = %{
      "action" => %{
        "namespace" => "access",
        "name" => name,
        "major" => 1,
        "schema" => digest(schema_digest)
      },
      "resources" => [
        %{
          "namespace" => "access.party",
          "path" => [Base.encode16(party, case: :lower)],
          "incarnation" => 0
        }
      ],
      "opaque" => %{"payload" => digest(payload)},
      "validity" => [from_ms, until_ms]
    }

    context("access/intent/v1", encode(envelope))
  end

  defp payload(:instance_create, party, key),
    do: %{"party" => {:bytes, party}, "key" => %{"ed25519" => {:bytes, key}}}

  defp payload(:party_register, party, _key) do
    %{
      "party" => {:bytes, party},
      "root" => %{"sole" => {:bytes, party}},
      "actor_kind" => "system"
    }
  end

  @doc "The Actor Intent Statement of one Exercise of a challenge (`mode` commit, `capacity` own), signed at `pairing.now_ms`."
  @spec statement(map(), %{nonce: binary(), intent: binary()}) :: binary()
  def statement(pairing, exercise) do
    encode(%{
      "domain" => digest(pairing.domain),
      "nonce" => {:bytes, exercise.nonce},
      "intent" => digest(exercise.intent),
      "mode" => "commit",
      "pep" => pairing.pep,
      "capacity" => "own",
      "basis" => %{"public" => {:bytes, pairing.basis}},
      "iat" => pairing.now_ms
    })
  end

  defp protected(kid), do: encode(%{1 => -19, 3 => @content_type, 4 => {:bytes, kid}})

  defp to_be_signed(protected, payload),
    do: encode(["Signature1", {:bytes, protected}, {:bytes, ""}, {:bytes, payload}])

  defp unsigned(protected, payload),
    do: <<0xD2, 0x84>> <> encode({:bytes, protected}) <> <<0xA0>> <> encode({:bytes, payload})

  @doc "Whether `sign1` is the tagged `COSE_Sign1` of `statement` with the protected header of `kid` (`alg` -19, the statement content type) and a signature of the Ed25519 key `key`."
  @spec signed?(binary(), binary(), <<_::256>>, <<_::256>>) :: boolean()
  def signed?(sign1, statement, <<_::256>> = kid, <<_::256>> = key) when is_binary(sign1) do
    protected = protected(kid)
    head = unsigned(protected, statement)
    size = byte_size(head)

    case sign1 do
      <<^head::binary-size(^size), 0x58, 0x40, signature::binary-64>> ->
        message = to_be_signed(protected, statement)
        :crypto.verify(:eddsa, :none, message, signature, [key, :ed25519])

      _other ->
        false
    end
  end

  @doc "The answer of the key store to a pairing challenge for the service key `key`, whose `sign` signs a message: the `COSE_Sign1` of `instance_create` and then of `party_register`, or the code of the first check that fails."
  @spec sign_pairing(map(), <<_::256>>, (binary() -> binary())) ::
          {:ok, [binary(), ...]} | {:refused, String.t()}
  def sign_pairing(pairing, <<_::256>> = key, sign) when is_function(sign, 1) do
    case challenge_refusal(pairing, key) || kernel_refusal(pairing, key) do
      nil ->
        exercises = Enum.reject([pairing.instance_create, pairing.party_register], &is_nil/1)
        {:ok, Enum.map(exercises, &sign1(pairing, &1, sign))}

      code ->
        {:refused, code}
    end
  end

  defp challenge_refusal(pairing, key) do
    cond do
      pairing.kid != thumbprint(key) -> "pairing-kid"
      pairing.instance_create.nonce != pairing.challenge -> "pairing-nonce"
      not register_nonce?(pairing) -> "pairing-register-nonce"
      not valid?(pairing) -> "pairing-validity"
      byte_size(pairing.pep) not in 1..255 -> "pairing-pep"
      true -> nil
    end
  end

  defp kernel_refusal(pairing, key) do
    window = {pairing.valid_from_ms, pairing.valid_until_ms}
    create = intent(:instance_create, pairing.party, key, window)

    cond do
      pairing.basis != bootstrap_basis(pairing.domain) -> "pairing-basis"
      pairing.instance_create.intent != create -> "pairing-instance-intent"
      not register_intent?(pairing, key, window) -> "pairing-register-intent"
      true -> nil
    end
  end

  defp register_intent?(%{party_register: nil}, _key, _window), do: true

  defp register_intent?(pairing, key, window),
    do: pairing.party_register.intent == intent(:party_register, pairing.party, key, window)

  defp register_nonce(pairing), do: pairing.challenge <> <<1>>

  defp register_nonce?(%{party_register: nil}), do: true
  defp register_nonce?(pairing), do: pairing.party_register.nonce == register_nonce(pairing)

  defp valid?(pairing) do
    pairing.valid_from_ms <= pairing.valid_until_ms and
      pairing.valid_until_ms - pairing.now_ms >= @min_validity_ms
  end

  defp sign1(pairing, exercise, sign) do
    protected = protected(pairing.kid)
    payload = statement(pairing, exercise)
    signature = sign.(to_be_signed(protected, payload))
    unsigned(protected, payload) <> <<0x58, 0x40>> <> signature
  end

  @doc "An `unpaired` target as Access issues it for the service key `key` at Unix millisecond `now_ms`: a fresh challenge with ten minutes of validity, the bootstrap Grant of the realm's domain as basis and both Exercises with the intent digests Access computes. `party_register: false` leaves the registration out."
  @spec target(<<_::256>>, integer(), keyword()) :: map()
  def target(<<_::256>> = key, now_ms, opts \\ []) do
    domain = :crypto.hash(:sha256, @realm)
    party = binary_part(:crypto.hash(:sha256, "party" <> @realm), 0, 16)
    challenge = Keyword.get_lazy(opts, :challenge, fn -> :crypto.strong_rand_bytes(32) end)
    window = {now_ms - 1_000, now_ms + 600_000}
    register = %{nonce: challenge <> <<1>>, intent: intent(:party_register, party, key, window)}

    %{
      status: :unpaired,
      realm: @realm,
      domain: domain,
      basis: bootstrap_basis(domain),
      pep: "access-identity",
      party: party,
      kid: thumbprint(key),
      challenge: challenge,
      valid_from_ms: elem(window, 0),
      valid_until_ms: elem(window, 1),
      instance_create: %{nonce: challenge, intent: intent(:instance_create, party, key, window)},
      party_register: if(Keyword.get(opts, :party_register, true), do: register)
    }
  end

  @doc "Targets made from `target`, each failing one check when signed before `target.valid_until_ms - 60_000`, with the code of the check."
  @spec tampered(map()) :: [{String.t(), map()}]
  def tampered(%{party_register: %{}} = target) do
    other = :crypto.hash(:sha256, "other")

    [
      {"pairing-kid", %{target | kid: other}},
      {"pairing-nonce", put_in(target.instance_create.nonce, other)},
      {"pairing-register-nonce", put_in(target.party_register.nonce, target.challenge <> <<2>>)},
      {"pairing-validity", %{target | valid_from_ms: target.valid_until_ms + 1}},
      {"pairing-pep", %{target | pep: ""}},
      {"pairing-basis", %{target | basis: binary_part(other, 0, 16)}},
      {"pairing-basis", %{target | domain: other}},
      {"pairing-instance-intent", put_in(target.instance_create.intent, other)},
      {"pairing-instance-intent", %{target | valid_until_ms: target.valid_until_ms + 1}},
      {"pairing-instance-intent", %{target | party: binary_part(other, 0, 16)}},
      {"pairing-register-intent", put_in(target.party_register.intent, other)}
    ]
  end
end
