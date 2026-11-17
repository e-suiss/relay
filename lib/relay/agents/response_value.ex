defmodule Relay.Agents.ResponseValue do
  @moduledoc """
  The value of a response (C-74, AG-25, E-86): its check against the waitpoint's response schema before anything is recorded (INV-31, AG-11), its canonical form and digest, and its sealed form. The digest is the SHA-256 of the RFC 8785 (JCS) form of the value: object members ordered by the UTF-16 code units of their names, numbers in their shortest ECMAScript form and strings with the minimal JSON escapes. The value is sealed under the responder's `notification_content` data key (subject × retention class), so the responder's erasure makes it unreadable wherever it is kept: in the response, in a consumed response token and in the waiter's mailbox record. The keys come from the step configured as `config :relay, Relay.Agents, field_keys: Module`, by default `Relay.Tenancy`.
  """

  alias Relay.Agents.ResponseStore

  @dialect "https://json-schema.org/draft/2020-12/schema"
  @max_bytes Relay.Limits.fetch!(["waitpoint", "max_response_bytes"])
  @class :notification_content
  @tenancy Relay.Tenancy

  # INV-31
  # AG-11
  # AG-53
  @doc "Checks a value against a response schema (JSON Schema 2020-12) and the response size limit; a waitpoint without a schema takes no response."
  @spec check(map() | nil, term()) :: :ok | {:error, :invalid}
  def check(schema, value) when is_map(schema) do
    with true <- byte_size(Jason.encode!(value)) <= @max_bytes,
         {:ok, root} <- root(schema),
         {:ok, _value} <- JSV.validate(value, root, cast: false) do
      :ok
    else
      _invalid -> {:error, :invalid}
    end
  end

  def check(_schema, _value), do: {:error, :invalid}

  defp root(schema) do
    JSV.build(schema, default_meta: @dialect)
  rescue
    _error -> {:error, :unbuildable}
  end

  # E-86
  @doc "The canonical (RFC 8785) form of a decoded JSON value."
  @spec canonical(term()) :: binary()
  def canonical(value), do: value |> encode() |> IO.iodata_to_binary()

  # E-86
  # AG-11
  @doc "The digest of a value: the SHA-256 of its canonical form."
  @spec digest(term()) :: <<_::256>>
  def digest(value), do: :crypto.hash(:sha256, canonical(value))

  defp encode(map) when is_map(map) do
    members =
      map
      |> Enum.map(fn {name, value} -> {to_string(name), value} end)
      |> Enum.sort_by(fn {name, _value} -> utf16(name) end)
      |> Enum.map(fn {name, value} -> [Jason.encode!(name), ":", encode(value)] end)

    ["{", Enum.intersperse(members, ","), "}"]
  end

  defp encode(list) when is_list(list),
    do: ["[", list |> Enum.map(&encode/1) |> Enum.intersperse(","), "]"]

  defp encode(number) when is_integer(number), do: Integer.to_string(number)
  defp encode(number) when is_float(number), do: float(number)
  defp encode(other), do: Jason.encode!(other)

  defp utf16(name), do: :unicode.characters_to_binary(name, :utf8, {:utf16, :big})

  defp float(number) when number == 0, do: "0"
  defp float(number) when number < 0, do: "-" <> float(-number)

  defp float(number) do
    {digits, point} = decimal(Float.to_string(number))
    count = byte_size(digits)

    cond do
      count <= point and point <= 21 ->
        digits <> String.duplicate("0", point - count)

      0 < point and point <= 21 ->
        binary_part(digits, 0, point) <> "." <> binary_part(digits, point, count - point)

      -6 < point and point <= 0 ->
        "0." <> String.duplicate("0", -point) <> digits

      true ->
        exponent(digits, point - 1)
    end
  end

  defp decimal(text) do
    {mantissa, exponent} =
      case String.split(text, "e") do
        [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
        [mantissa] -> {mantissa, 0}
      end

    [whole, fraction] = String.split(mantissa, ".")
    all = whole <> fraction
    significant = String.trim_leading(all, "0")
    leading = byte_size(all) - byte_size(significant)
    {String.trim_trailing(significant, "0"), byte_size(whole) + exponent - leading}
  end

  defp exponent(<<first::binary-1>>, power), do: first <> "e" <> signed(power)

  defp exponent(<<first::binary-1, rest::binary>>, power),
    do: first <> "." <> rest <> "e" <> signed(power)

  defp signed(power) when power < 0, do: Integer.to_string(power)
  defp signed(power), do: "+" <> Integer.to_string(power)

  # OP-18
  # TN-27
  @doc "Seals a value for a responder under the responder's data key, registering the key when the responder has none; called outside any transaction. Returns the ciphertext, the key and the digest of the value."
  @spec seal(Relay.Scope.t(), Relay.Id.t(), term()) ::
          {:ok, %{value_ct: binary(), value_key_id: Relay.Id.t(), value_digest: <<_::256>>}}
          | {:error, term()}
  def seal(%Relay.Scope{} = scope, recipient_id, value) do
    with {:ok, key_id, opts} <- key(scope, recipient_id),
         plain = Jason.encode!(value),
         {:ok, ct} <- tenancy().encrypt_field(field(scope, recipient_id), plain, opts) do
      {:ok, %{value_ct: ct, value_key_id: key_id, value_digest: digest(value)}}
    end
  end

  # AG-25
  # OP-24
  @doc "Opens a sealed value of a responder; `:error` when it cannot be read, as after the responder's erasure. Called outside any transaction."
  @spec open(Relay.Scope.t(), Relay.Id.t(), binary() | nil) :: {:ok, term()} | :error
  def open(_scope, _recipient_id, nil), do: :error

  def open(%Relay.Scope{} = scope, recipient_id, ct) when is_binary(ct) do
    with {:ok, plain} <- tenancy().decrypt_field(field(scope, recipient_id), ct),
         {:ok, value} <- Jason.decode(Relay.Redacted.expose(plain)) do
      {:ok, value}
    else
      _unreadable -> :error
    end
  end

  defp tenancy,
    do: :relay |> Application.get_env(Relay.Agents, []) |> Keyword.get(:field_keys, @tenancy)

  defp field(scope, recipient_id) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: recipient_id,
      retention_class: @class,
      table: "waitpoint_responses",
      column: "value_ct"
    }
  end

  defp key(scope, recipient_id) do
    id = Relay.Id.generate()

    with {:ok, wrap_id} <- tenancy().active_tenant_key(scope, :dek_wrap),
         {:ok, %{wrapped_dek: wrapped, data_key: data_key}} <-
           tenancy().generate_subject_key(scope, wrap_id, recipient_id, @class),
         {:ok, created} <- register(scope, id, recipient_id, wrapped, wrap_id) do
      case created do
        {:created, ^id} -> {:ok, id, [data_key: data_key]}
        {:exists, key_id} -> {:ok, key_id, []}
        {_missing, _id} -> {:error, :responder_unavailable}
      end
    end
  end

  defp register(scope, id, recipient_id, wrapped, wrap_id) do
    ResponseStore.in_scope(scope, fn _status ->
      ResponseStore.subject_key_create(id, recipient_id, Atom.to_string(@class), wrapped, wrap_id)
    end)
  end
end
