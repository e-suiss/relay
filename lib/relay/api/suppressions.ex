defmodule Relay.Api.Suppressions do
  @moduledoc """
  Address suppressions on the server and operator APIs (PC-59 (2)): list, a manual or `invalid` suppression of one address on one channel, and lifting with a reason. The address is held only as the blind index of the tenant and is never stored or returned in clear. A tenant lifts `manual` and `invalid` suppressions (`403 suppression_lift_forbidden` otherwise); a tenant administrator with step-up lifts any reason through the operator API.
  """

  alias Relay.Api.Page
  alias Relay.Api.Views

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @channels ~w(push web_push email sms voice whatsapp slack teams telegram discord in_app webhook)
  @reasons ~w(hard_bounce complaint invalid soft_bounce manual)
  @states ~w(active expired lifted)
  @phone_channels ~w(sms voice whatsapp)

  # PC-59 (2)
  @doc "The API view of a suppression row."
  @spec view(map()) :: map()
  def view(s) do
    %{
      "object" => "suppression",
      "id" => Views.id("sup", s["id"]),
      "channel" => s["channel"],
      "reason" => s["reason"],
      "state" => state(s),
      "expires_at" => s["expires_at"],
      "created_at" => s["created_at"],
      "lifted_at" => s["lifted_at"],
      "lifted_by" => s["lifted_by_ref"],
      "lift_reason" => s["lift_reason"]
    }
  end

  defp state(%{"lifted_at" => %DateTime{}}), do: "lifted"

  defp state(%{"expires_at" => %DateTime{} = at}) do
    if DateTime.compare(at, Relay.Clock.utc_now()) == :gt, do: "active", else: "expired"
  end

  defp state(_row), do: "active"

  # PC-59 (2)
  # OP-20
  @doc "Prepares a suppression request outside any transaction: the address is checked for its channel and digested under every readable blind index key."
  @spec prepare(Relay.Scope.t(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def prepare(scope, body) do
    channel = body["channel"]
    reason = Map.get(body, "reason", "manual")

    with :ok <- address(channel, body["address"]),
         {:ok, expires_at} <- expiry(reason, body["expires_at"]),
         {:ok, digests} <- digests(scope, channel, body["address"]) do
      {:ok, %{channel: channel, digests: digests, reason: reason, expires_at: expires_at}}
    end
  end

  defp address("email", address) do
    case Relay.Email.new(address) do
      {:ok, _redacted} -> :ok
      {:error, _error} -> field("/address", "invalid_format", "not an email address")
    end
  end

  defp address(channel, address) when channel in @phone_channels do
    case Relay.Phone.new(address) do
      {:ok, _redacted} -> :ok
      {:error, _error} -> field("/address", "invalid_format", "not an E.164 phone number")
    end
  end

  defp address(_channel, _address), do: :ok

  defp expiry(_reason, nil), do: {:ok, nil}

  defp expiry("manual", text) do
    {:ok, at, _offset} = DateTime.from_iso8601(text)

    if DateTime.compare(at, Relay.Clock.utc_now()) == :gt,
      do: {:ok, at},
      else: field("/expires_at", "unsupported_value", "the time is in the past")
  end

  defp expiry(_reason, _text),
    do: field("/expires_at", "not_allowed", "only a manual suppression expires")

  defp digests(scope, channel, address) do
    case Relay.Preferences.address_digests(scope, channel, address) do
      {:ok, digests} -> {:ok, digests}
      {:error, _error} -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  # PC-59 (2)
  @doc "Adds a prepared suppression inside the request's transaction; an equal active one is `200` and changes nothing."
  @spec create(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create(scope, prepared, actor) do
    case Relay.Preferences.add_suppression(scope, prepared, actor) do
      {:added, id} ->
        {:ok, {201, [], view(Relay.Preferences.suppression(id))}}

      {:exists, id} ->
        {:ok, {200, [], view(Relay.Preferences.suppression(id))}}

      {:invalid_expiry, _id} ->
        field("/expires_at", "unsupported_value", "the time is in the past")

      {:key_not_found, _id} ->
        {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  # PC-59 (2)
  # TN-22
  @doc "Lifts a suppression inside the request's transaction as `lifter` (`tenant` or `operator`); lifting a lifted suppression returns it."
  @spec lift(Relay.Scope.t(), Relay.Id.t(), map(), Relay.Actor.t()) :: answer()
  def lift(scope, id, lift, actor) do
    case Relay.Preferences.lift_suppression(scope, id, lift, actor) do
      result when result in [:lifted, :already_lifted] ->
        {:ok, {200, [], view(Relay.Preferences.suppression(id))}}

      :not_found ->
        {:error, not_found()}

      :lift_forbidden ->
        {:error,
         Relay.Error.new(
           :suppression_lift_forbidden,
           "a tenant lifts only manual and invalid suppressions"
         )}

      :step_up_required ->
        {:error, Relay.Error.new(:auth_step_up_required, "step-up is required")}
    end
  end

  # PC-59 (2)
  # TN-22
  @doc "Lifts a suppression of any reason for a tenant administrator with step-up, in a transaction of its own; `{:ok, {200, view}}`."
  @spec lift_as_operator(Relay.Scope.t(), Relay.Id.t(), map(), Relay.Actor.t()) ::
          {:ok, {200, map()}} | {:error, Relay.Error.t()}
  def lift_as_operator(scope, id, lift, actor) do
    work = fn _status -> lift(scope, id, Map.put(lift, :lifter, "operator"), actor) end

    case Relay.Preferences.in_scope(scope, work) do
      {:ok, {:ok, {200, [], view}}} -> {:ok, {200, view}}
      {:ok, {:error, %Relay.Error{} = error}} -> {:error, error}
      {:error, %Relay.Error{code: :not_found}} -> {:error, not_found()}
      {:error, _reason} -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  # API-56
  @doc "Reads the `channel`, `reason` and `state` filters of a list request; every invalid one is reported."
  @spec filters(map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def filters(query) do
    checks = [channel: @channels, reason: @reasons, state: @states]

    {filters, errors} =
      Enum.reduce(checks, {%{}, []}, fn {name, allowed}, {filters, errors} ->
        filter(name, Map.get(query, Atom.to_string(name)), allowed, {filters, errors})
      end)

    if errors == [],
      do: {:ok, filters},
      else: {:error, Relay.Error.new(:validation_failed, "invalid filters", %{errors: errors})}
  end

  defp filter(_name, nil, _allowed, acc), do: acc

  defp filter(name, value, allowed, {filters, errors}) do
    if value in allowed,
      do: {Map.put(filters, name, value), errors},
      else: {filters, errors ++ [invalid(name)]}
  end

  defp invalid(name) do
    text = Atom.to_string(name)
    %{pointer: "/" <> text, code: "unsupported_value", detail: "#{text} is not supported"}
  end

  # API-56
  @doc "Lists suppressions."
  @spec list(Relay.Scope.t(), map(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def list(scope, filters, page, endpoint) do
    case Relay.Preferences.list_suppressions(scope, filters, page.cursor, page.limit) do
      {:ok, rows} ->
        position = &{&1["cursor_at"], &1["id"]}

        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, position),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  defp field(pointer, code, detail) do
    {:error,
     Relay.Error.new(:validation_failed, detail, %{
       errors: [%{pointer: pointer, code: code, detail: detail}]
     })}
  end

  @doc "The error of an unknown suppression."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:suppression_not_found, "no such suppression")
end
