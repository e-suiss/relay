defmodule Relay.Api.Cursor do
  @moduledoc """
  Opaque, signed pagination cursors (API-56):

      cursor = base64url(payload ‖ HMAC-SHA256(K_cursor, det-CBOR([tenant_id, environment, subject, payload]))[0..16))
      payload = det-CBOR([1, endpoint, sort_ts_us, id_bytes, direction])

  `K_cursor` is an installation key in the key store (`Relay.Keys.cursor_label/0`); the HMAC is computed inside it. `subject` is the subscriber of a client endpoint and `nil` elsewhere. A cursor binds to its tenant, environment, subject and endpoint and is never stored. A cursor of the other environment is `auth_environment_mismatch` (API-76 (2)); any other cursor that does not verify, another tenant's included, is `validation_failed` on its parameter.
  """

  alias Relay.Canonical
  alias Relay.Redacted

  @version 1
  @tag_bytes 16
  @directions ["after", "before"]

  @type position :: %{sort_ts_us: non_neg_integer(), id: Relay.Id.t()}
  @type direction :: :after | :before
  @type decoded :: %{sort_ts_us: non_neg_integer(), id: Relay.Id.t(), direction: direction()}

  # API-56
  @doc "Signs a cursor for the position after (or before) which the next page starts."
  @spec encode(Relay.Scope.t(), Relay.Id.t() | nil, String.t(), position(), direction()) ::
          {:ok, String.t()} | {:error, Relay.Error.t()}
  def encode(%Relay.Scope{} = scope, subject, endpoint, position, direction)
      when direction in [:after, :before] do
    payload =
      Canonical.encode!([
        @version,
        endpoint,
        position.sort_ts_us,
        {:bytes, position.id},
        Atom.to_string(direction)
      ])

    with {:ok, tag} <- tag(scope.tenant_id, scope.environment, subject, payload),
         do: {:ok, Base.url_encode64(payload <> tag, padding: false)}
  end

  # API-56
  # API-76 (2)
  @doc "Verifies and reads a cursor given in the query parameter `param` of `endpoint`."
  @spec decode(Relay.Scope.t(), Relay.Id.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, decoded()} | {:error, Relay.Error.t()}
  def decode(%Relay.Scope{} = scope, subject, endpoint, cursor, param) when is_binary(cursor) do
    with {:ok, raw} <- base64(cursor),
         {:ok, payload, tag} <- split(raw),
         {:ok, expected} <- tag(scope.tenant_id, scope.environment, subject, payload) do
      cond do
        Plug.Crypto.secure_compare(tag, expected) -> read(payload, endpoint, param)
        other_environment?(scope, subject, payload, tag) -> mismatch()
        true -> invalid(param)
      end
    else
      {:error, %Relay.Error{code: :invalid_cursor}} -> invalid(param)
      {:error, %Relay.Error{} = error} -> {:error, error}
    end
  end

  def decode(_scope, _subject, _endpoint, _cursor, param), do: invalid(param)

  defp other_environment?(scope, subject, payload, tag) do
    other = if scope.environment == :live, do: :test, else: :live

    case tag(scope.tenant_id, other, subject, payload) do
      {:ok, expected} -> Plug.Crypto.secure_compare(tag, expected)
      {:error, _error} -> false
    end
  end

  defp tag(tenant_id, environment, subject, payload) do
    message =
      Canonical.encode!([
        {:bytes, tenant_id},
        Relay.Environment.dump(environment),
        if(subject, do: {:bytes, subject}),
        {:bytes, payload}
      ])

    with {:ok, label} <- Relay.Keys.cursor_label(),
         {:ok, <<tag::binary-size(@tag_bytes), _rest::binary>>} <-
           Relay.Keys.hmac_sha256(label, Redacted.wrap(message)),
         do: {:ok, tag}
  end

  defp base64(cursor) do
    case Base.url_decode64(cursor, padding: false) do
      {:ok, raw} -> {:ok, raw}
      :error -> invalid_cursor()
    end
  end

  defp split(raw) when byte_size(raw) > @tag_bytes do
    size = byte_size(raw) - @tag_bytes
    <<payload::binary-size(^size), tag::binary-size(@tag_bytes)>> = raw
    {:ok, payload, tag}
  end

  defp split(_raw), do: invalid_cursor()

  defp read(payload, endpoint, param) do
    with {:ok, [@version, ^endpoint, sort_ts_us, {:bytes, <<_::128>> = id}, direction], ""}
         when is_integer(sort_ts_us) and direction in @directions <- items(payload) do
      {:ok, %{sort_ts_us: sort_ts_us, id: id, direction: direction(direction)}}
    else
      _ -> invalid(param)
    end
  end

  defp direction("after"), do: :after
  defp direction("before"), do: :before

  defp items(<<4::3, 5::5, rest::binary>>), do: take(rest, 5, [])
  defp items(_payload), do: :error

  defp take(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp take(binary, n, acc) do
    case item(binary) do
      {:ok, value, rest} -> take(rest, n - 1, [value | acc])
      :error -> :error
    end
  end

  defp item(<<major::3, info::5, rest::binary>>) when major in [0, 2, 3] do
    with {:ok, n, rest} <- argument(info, rest) do
      case {major, rest} do
        {0, rest} -> {:ok, n, rest}
        {2, <<bytes::binary-size(^n), rest::binary>>} -> {:ok, {:bytes, bytes}, rest}
        {3, <<text::binary-size(^n), rest::binary>>} -> {:ok, text, rest}
        _ -> :error
      end
    end
  end

  defp item(_binary), do: :error

  defp argument(info, rest) when info < 24, do: {:ok, info, rest}
  defp argument(24, <<n::8, rest::binary>>), do: {:ok, n, rest}
  defp argument(25, <<n::16, rest::binary>>), do: {:ok, n, rest}
  defp argument(26, <<n::32, rest::binary>>), do: {:ok, n, rest}
  defp argument(27, <<n::64, rest::binary>>), do: {:ok, n, rest}
  defp argument(_info, _rest), do: :error

  defp invalid_cursor, do: {:error, Relay.Error.new(:invalid_cursor, "not a cursor")}

  defp mismatch,
    do:
      {:error,
       Relay.Error.new(:auth_environment_mismatch, "the cursor belongs to the other environment")}

  defp invalid(param) do
    {:error,
     Relay.Error.new(:validation_failed, "the cursor is not valid here", %{
       errors: [%{pointer: "/" <> param, code: "invalid_format", detail: "invalid cursor"}]
     })}
  end
end
