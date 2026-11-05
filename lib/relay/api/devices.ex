defmodule Relay.Api.Devices do
  @moduledoc """
  The device operations (API-46, API-67) of the server API (`/v1/subscribers/{id}/devices`, `/v1/devices/by-token`) and of the subscriber API (`/v1/subscriber/devices`, scope `devices:write`). A registration is prepared outside the transaction (digests and encryption) and written inside the request's idempotency transaction; a new device is `201`, a refreshed one `200`. The token is never returned: a device answers with its fingerprint. Removing a device disables it (`removed` from the server API, `logout` from the subscriber API) and answers it.
  """

  alias Relay.Api.Page
  alias Relay.Api.Views

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # API-67
  @doc "The API view of a device row."
  @spec view(map()) :: map()
  def view(d) do
    %{
      "object" => "device",
      "id" => Views.id("dev", d["id"]),
      "subscriber_id" => Views.id("sub", d["recipient_id"]),
      "platform" => d["platform"],
      "app" => d["app"],
      "token_fingerprint" => d["fingerprint"],
      "apns_environment" => d["apns_environment"],
      "permission" => d["permission"],
      "android_channels" => d["android_channels"],
      "locale" => d["locale"],
      "state" => d["state"],
      "disabled_reason" => d["disabled_reason"],
      "registered_at" => d["registered_at"],
      "last_seen_at" => d["last_seen_at"],
      "deleted_at" => d["deleted_at"],
      "created_at" => d["created_at"],
      "updated_at" => d["updated_at"]
    }
  end

  # API-67
  # API-46
  @doc "Prepares a registration for a subscriber outside any transaction."
  @spec prepare(Relay.Scope.t(), Relay.Id.t(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def prepare(scope, recipient_id, body) do
    case Relay.Devices.prepare(scope, recipient_id, body) do
      {:ok, plan} -> {:ok, plan}
      {:error, %Relay.Error{code: :validation_failed} = error} -> {:error, error}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # API-67
  # CH-74
  @doc "Registers a prepared device inside the request's transaction and answers with it."
  @spec register(map()) :: answer()
  def register(plan) do
    case Relay.Devices.register(plan) do
      {result, id} when result in [:created, :reassigned] -> {:ok, {201, [], device(id)}}
      {:updated, id} -> {:ok, {200, [], device(id)}}
      {:recipient_not_found, _id} -> {:error, subscriber_not_found()}
      {:key_not_found, _id} -> {:error, unavailable()}
    end
  end

  # API-56
  # API-67
  @doc "Lists the devices of a subscriber that are not disabled, most recently seen first, in pages."
  @spec list(Relay.Scope.t(), Relay.Id.t(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def list(scope, recipient_id, page, endpoint) do
    case Relay.Devices.list(scope, recipient_id) do
      {:ok, rows} ->
        position = &{&1["last_seen_at"], &1["id"]}
        rows = window(rows, page)

        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, position),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  defp window(rows, %{cursor: cursor, limit: limit}) do
    sorted = Enum.sort_by(rows, &sort_key/1, :desc)

    case cursor do
      nil ->
        Enum.take(sorted, limit + 1)

      %{direction: :after, sort_ts_us: ts, id: id} ->
        sorted |> Enum.filter(&(sort_key(&1) < {ts, id})) |> Enum.take(limit + 1)

      %{direction: :before, sort_ts_us: ts, id: id} ->
        sorted
        |> Enum.filter(&(sort_key(&1) > {ts, id}))
        |> Enum.reverse()
        |> Enum.take(limit + 1)
    end
  end

  defp sort_key(row), do: {DateTime.to_unix(row["last_seen_at"], :microsecond), row["id"]}

  # API-67
  # CH-31
  @doc "Disables a device inside the request's transaction, by identifier or by token digests and, with `recipient_id`, only among that subscriber's devices; answers with the device."
  @spec remove(
          {:device, Relay.Id.t()} | {:digests, [binary()]},
          Relay.Id.t() | nil,
          :removed | :logout
        ) :: answer()
  def remove(ref, recipient_id, reason) do
    case Relay.Devices.remove(ref, recipient_id, reason) do
      {result, id} when result in [:disabled, :already_disabled] -> {:ok, {200, [], device(id)}}
      {_not_found, _id} -> {:error, device_not_found()}
    end
  end

  # API-67
  @doc "The blind indexes of a token named in a request, computed outside any transaction."
  @spec token_digests(Relay.Scope.t(), String.t()) ::
          {:ok, [binary()]} | {:error, Relay.Error.t()}
  def token_digests(scope, token) do
    case Relay.Devices.token_digests(scope, token) do
      {:ok, digests} -> {:ok, digests}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp device(id), do: id |> Relay.Devices.get() |> view()

  @doc "The error of a device that is not found."
  @spec device_not_found() :: Relay.Error.t()
  def device_not_found, do: Relay.Error.new(:device_not_found, "no device has this id or token")

  defp subscriber_not_found,
    do: Relay.Error.new(:subscriber_not_found, "no subscriber has this id")

  defp unavailable do
    message = "the device could not be written"
    Relay.Error.new(:service_unavailable, message, %{retry_after: 1})
  end
end
