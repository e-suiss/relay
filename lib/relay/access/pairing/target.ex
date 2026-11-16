defmodule Relay.Access.Pairing.Target do
  @moduledoc """
  The pure rules of the pairing answers (E-101, Access OP-149 m.16–19): an answer of either pairing route (`PairingChallenges` or `PairingResult`) and its targets, the checks of an `unpaired` target that need no Access kernel, and the body of the pairing request.

  A target names one realm (a canonical lower-case UUID) and is `paired` (the Instance an earlier pairing with the current service key opened: `party`, `instance` and `kid`), `refused` (with Access's `code`) or `unpaired` (a challenge: the realm's governing `domain`, the Genesis bootstrap Grant `basis`, the `pep`, Relay's service `party`, the registered `kid`, the 32-byte `challenge`, the validity window and the `instance_create` and, while the Party is new, `party_register` Exercises with their nonces and Access's intent digests). Every binary member is base64url without padding; an answer for another tenant, a target that does not read and two targets of one realm make the whole answer invalid.

  Before anything of an `unpaired` target is signed, `check/3` asks that its `kid` is the thumbprint of the service key, that the `instance_create` nonce is the challenge and the `party_register` nonce the challenge followed by `0x01`, that the window is not reversed and at least 60 seconds of it are left, and that the PEP name holds 1 to 255 bytes. The kernel checks (the basis and the recomputed intent digests) belong to the signer (`Relay.Access.Pairing.Signer`).
  """

  alias Relay.Access.Jose

  @min_validity_ms 60_000
  @max_targets 64
  @register_suffix 0x01
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @time ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z\z/

  @type exercise :: %{nonce: binary(), intent: <<_::256>>}
  @type unpaired :: %{
          status: :unpaired,
          realm: String.t(),
          domain: <<_::256>>,
          basis: <<_::128>>,
          pep: String.t(),
          party: <<_::128>>,
          kid: <<_::256>>,
          challenge: <<_::256>>,
          valid_from_ms: integer(),
          valid_until_ms: integer(),
          instance_create: exercise(),
          party_register: exercise() | nil
        }
  @type paired :: %{
          status: :paired,
          realm: String.t(),
          party: <<_::128>>,
          instance: <<_::128>>,
          kid: <<_::256>>
        }
  @type refused :: %{status: :refused, realm: String.t(), code: String.t()}
  @type t :: unpaired() | paired() | refused()
  @type answer :: %{tenant: String.t(), targets: [t()], event_stream: String.t() | nil}
  @type signed :: %{
          realm: String.t(),
          challenge: <<_::256>>,
          ais: binary(),
          register_ais: binary() | nil
        }
  @type unsignable :: String.t()

  @doc "The least validity a challenge must have left to be signed, in milliseconds."
  @spec min_validity_ms() :: pos_integer()
  def min_validity_ms, do: @min_validity_ms

  @doc "The most targets one pairing request carries."
  @spec max_targets() :: pos_integer()
  def max_targets, do: @max_targets

  @doc "Whether `text` is a canonical lower-case UUID, the spelling of Access's realm and stream ids."
  @spec uuid?(term()) :: boolean()
  def uuid?(text) when is_binary(text), do: Regex.match?(@uuid, text)
  def uuid?(_text), do: false

  # E-101
  @doc "The `party_register` nonce of a challenge: the challenge followed by `0x01`."
  @spec register_nonce(binary()) :: binary()
  def register_nonce(challenge) when is_binary(challenge), do: challenge <> <<@register_suffix>>

  # E-101
  @doc "Reads an answer of either pairing route for `tenant`."
  @spec parse(term(), String.t()) :: {:ok, answer()} | :error
  def parse(%{"tenant" => tenant, "targets" => targets} = document, tenant)
      when is_list(targets) do
    with true <- stream?(document["event_stream"]),
         {:ok, parsed} <- all(targets),
         true <- distinct?(parsed) do
      {:ok, %{tenant: tenant, targets: parsed, event_stream: document["event_stream"]}}
    else
      _invalid -> :error
    end
  end

  def parse(_document, _tenant), do: :error

  defp stream?(nil), do: true
  defp stream?(stream), do: uuid?(stream)

  defp all(targets) do
    parsed = Enum.map(targets, &target/1)

    if Enum.all?(parsed, &match?({:ok, _target}, &1)),
      do: {:ok, Enum.map(parsed, &elem(&1, 1))},
      else: :error
  end

  defp distinct?(targets) do
    realms = Enum.map(targets, & &1.realm)
    length(Enum.uniq(realms)) == length(realms)
  end

  defp target(%{"realm" => realm, "status" => status} = wire) do
    if uuid?(realm), do: target(status, realm, wire), else: :error
  end

  defp target(_wire), do: :error

  defp target("paired", realm, wire) do
    with {:ok, party} <- fixed(wire["party"], 16),
         {:ok, instance} <- fixed(wire["instance"], 16),
         {:ok, kid} <- fixed(wire["kid"], 32) do
      {:ok, %{status: :paired, realm: realm, party: party, instance: instance, kid: kid}}
    end
  end

  defp target("refused", realm, %{"code" => code})
       when is_binary(code) and byte_size(code) in 1..128,
       do: {:ok, %{status: :refused, realm: realm, code: code}}

  defp target("unpaired", realm, wire) do
    with {:ok, keys} <- keys(wire),
         {:ok, window} <- window(wire),
         {:ok, create} <- exercise(wire["instance_create"]),
         {:ok, register} <- optional_exercise(wire["party_register"]),
         pep when is_binary(pep) <- wire["pep"] do
      fields = %{status: :unpaired, realm: realm, pep: pep, instance_create: create}
      {:ok, fields |> Map.merge(keys) |> Map.merge(window) |> Map.put(:party_register, register)}
    else
      _invalid -> :error
    end
  end

  defp target(_status, _realm, _wire), do: :error

  defp keys(wire) do
    with {:ok, domain} <- fixed(wire["domain"], 32),
         {:ok, basis} <- fixed(wire["basis"], 16),
         {:ok, party} <- fixed(wire["party"], 16),
         {:ok, kid} <- fixed(wire["kid"], 32),
         {:ok, challenge} <- fixed(wire["challenge"], 32) do
      {:ok, %{domain: domain, basis: basis, party: party, kid: kid, challenge: challenge}}
    end
  end

  defp window(wire) do
    with {:ok, from} <- time_ms(wire["valid_from"]),
         {:ok, until} <- time_ms(wire["valid_until"]),
         do: {:ok, %{valid_from_ms: from, valid_until_ms: until}}
  end

  defp exercise(%{"nonce" => nonce, "intent" => intent}) do
    with {:ok, nonce} <- bytes(nonce),
         true <- byte_size(nonce) in 16..64,
         {:ok, intent} <- fixed(intent, 32) do
      {:ok, %{nonce: nonce, intent: intent}}
    else
      _invalid -> :error
    end
  end

  defp exercise(_wire), do: :error

  defp optional_exercise(nil), do: {:ok, nil}
  defp optional_exercise(wire), do: exercise(wire)

  defp fixed(text, size) do
    case bytes(text) do
      {:ok, value} when byte_size(value) == size -> {:ok, value}
      _invalid -> :error
    end
  end

  defp bytes(text) when is_binary(text) do
    case Jose.decode(text) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp bytes(_text), do: :error

  # E-101
  @doc "Unix milliseconds of RFC 3339 UTC text `YYYY-MM-DDTHH:MM:SS[.f{1,3}]Z`, the only form Access writes."
  @spec time_ms(term()) :: {:ok, integer()} | :error
  def time_ms(text) when is_binary(text) do
    with true <- Regex.match?(@time, text),
         {:ok, at, 0} <- DateTime.from_iso8601(text) do
      {:ok, DateTime.to_unix(at, :millisecond)}
    else
      _invalid -> :error
    end
  end

  def time_ms(_text), do: :error

  # E-101
  @doc "The checks of an `unpaired` target that need no Access kernel, for the service key's thumbprint `kid` at Unix millisecond `now_ms`; the error is the stable code of the operator signal."
  @spec check(unpaired(), <<_::256>>, integer()) :: :ok | {:error, unsignable()}
  def check(%{status: :unpaired} = target, kid, now_ms) do
    cond do
      target.kid != kid -> {:error, "pairing-kid"}
      target.instance_create.nonce != target.challenge -> {:error, "pairing-nonce"}
      not register_nonce?(target) -> {:error, "pairing-register-nonce"}
      not valid_window?(target, now_ms) -> {:error, "pairing-validity"}
      byte_size(target.pep) not in 1..255 -> {:error, "pairing-pep"}
      true -> :ok
    end
  end

  defp register_nonce?(%{party_register: nil}), do: true

  defp register_nonce?(%{party_register: %{nonce: nonce}, challenge: challenge}),
    do: nonce == register_nonce(challenge)

  defp valid_window?(target, now_ms) do
    target.valid_from_ms <= target.valid_until_ms and
      target.valid_until_ms - now_ms >= @min_validity_ms
  end

  # E-101
  @doc "The body of `POST <pairing>` for 1 to 64 signed targets."
  @spec pairing_body([signed()]) :: {:ok, map()} | :error
  def pairing_body(signed)
      when is_list(signed) and signed != [] and length(signed) <= @max_targets,
      do: {:ok, %{"targets" => Enum.map(signed, &answer/1)}}

  def pairing_body(_signed), do: :error

  defp answer(signed) do
    base = %{
      "realm" => signed.realm,
      "challenge" => Jose.encode(signed.challenge),
      "ais" => Jose.encode(signed.ais)
    }

    if signed.register_ais,
      do: Map.put(base, "register_ais", Jose.encode(signed.register_ais)),
      else: base
  end
end
