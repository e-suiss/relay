defmodule Relay.Api.Iys do
  @moduledoc """
  The İYS connection of a tenant environment on the server API (PC-29, PC-30, PC-34, E-22): the configuration with its brands is read and replaced as a whole, the brands are listed with what İYS authorises for them, the connection is tested, and the uploads of the write path are listed, `failed` being the operator's queue of the movements İYS refused for good.

  The configuration names the connection mode (`own` or `integrator`), the İYS API (`production` or `sandbox`), the `iys_code`, in integrator mode the `integrator_code`, the API user name and the identifier of the registered secret reference that holds the password; the password itself is never taken or shown here (TN-26). A brand is bound to the tenant, to a sub-tenant or to an SMS sender identity whose registration names the same brand code. The replacement runs inside the request's transaction and is audited as `iys_config.replaced`. An upload never shows an address.
  """

  alias Relay.Api.Gate
  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Views
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @states ~w(pending uploaded confirmed failed expired skipped)

  # PC-29
  @doc "The İYS configuration of the scope; `404 iys_not_configured` when the tenant entered none."
  @spec get(Scope.t()) :: answer()
  def get(%Scope{} = scope) do
    case Relay.Iys.get_config(scope) do
      {:ok, %{config: %{} = config, brands: brands}} -> {:ok, {200, [], view(config, brands)}}
      {:ok, %{config: nil}} -> {:error, not_configured()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # PC-29
  @doc "The active brands of the scope with their authorisations."
  @spec brands(Scope.t()) :: answer()
  def brands(%Scope{} = scope) do
    case Relay.Iys.get_config(scope) do
      {:ok, %{brands: brands}} ->
        list = %{
          "object" => "list",
          "data" => Enum.map(brands, &brand_view/1),
          "has_more" => false,
          "next_cursor" => nil
        }

        {:ok, {200, [], list}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # PC-29
  # E-22
  @doc "Replaces the configuration and the brand set inside the request's transaction."
  @spec replace(Scope.t(), map(), Relay.Actor.t()) :: answer()
  def replace(%Scope{} = scope, body, actor) do
    with {:ok, config} <- config(body),
         {:ok, brands} <- brand_inputs(body["brands"]) do
      digest = Gate.digest(scope, "iys_config.replaced", Integer.to_string(config["iys_code"]))
      expected = body["expected_version"]
      replaced(Relay.Iys.put_config(config, brands, expected, digest, actor))
    end
  end

  defp config(%{"mode" => mode} = body) do
    integrator = body["integrator_code"]

    cond do
      mode == "integrator" and integrator == nil ->
        {:error, Gate.field_error("/integrator_code", "required", "the integrator's İYS code")}

      mode == "own" and integrator != nil ->
        {:error, Gate.field_error("/integrator_code", "not_allowed", "only in integrator mode")}

      true ->
        credential(body)
    end
  end

  defp credential(body) do
    case Relay.ExternalId.decode(body["credential_ref_id"], ["sec"]) do
      {:ok, id} ->
        {:ok,
         %{
           "mode" => body["mode"],
           "api" => body["api"],
           "iys_code" => body["iys_code"],
           "integrator_code" => body["integrator_code"],
           "username" => body["username"],
           "credential_ref_id" => Relay.Id.to_string(id)
         }}

      {:error, _error} ->
        {:error, no_secret()}
    end
  end

  defp brand_inputs(brands) do
    brands
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {brand, index}, {:ok, acc} ->
      case brand_input(brand, index) do
        {:ok, input} -> {:cont, {:ok, [input | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, inputs} -> {:ok, Enum.reverse(inputs)}
      error -> error
    end
  end

  defp brand_input(brand, index) do
    subtenant = reference(brand["subtenant_id"], "stn", index, "subtenant_id")
    sender = reference(brand["sender_identity_id"], "snd", index, "sender_identity_id")

    with {:ok, subtenant} <- subtenant,
         {:ok, sender} <- sender do
      {:ok,
       %{
         "brand_code" => brand["brand_code"],
         "name" => brand["name"],
         "subtenant_id" => subtenant,
         "sender_identity_id" => sender
       }}
    end
  end

  defp reference(nil, _prefix, _index, _field), do: {:ok, nil}

  defp reference(text, prefix, index, field) do
    case Relay.ExternalId.decode(text, [prefix]) do
      {:ok, id} -> {:ok, Relay.Id.to_string(id)}
      {:error, _error} -> {:error, brand_error(index, field, "not_found", "no such resource")}
    end
  end

  defp brand_error(index, field, code, detail),
    do: Gate.field_error("/brands/#{index}/#{field}", code, detail)

  defp replaced({result, _version}) when result in [:created, :updated] do
    %{config: config, brands: brands} = Relay.Iys.stored_config()
    {:ok, {200, [], view(config, brands)}}
  end

  defp replaced({:version_conflict, _version}),
    do: {:error, Relay.Error.new(:resource_conflict, "the configuration changed; read it again")}

  defp replaced({:tenant_inactive, _version}),
    do: {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}

  defp replaced({:sandbox_required, _version}),
    do: {:error, Gate.field_error("/api", "not_allowed", "a test environment uses the sandbox")}

  defp replaced({:secret_not_found, _version}), do: {:error, no_secret()}

  defp replaced({:binding_conflict, _version}),
    do: {:error, Gate.field_error("/brands", "conflict", "a brand code or a binding is repeated")}

  defp replaced({:subtenant_not_found, _version}),
    do: {:error, Gate.field_error("/brands", "not_found", "no such sub-tenant")}

  defp replaced({:sender_identity_not_found, _version}),
    do: {:error, Gate.field_error("/brands", "not_found", "no such sender identity")}

  defp replaced({:sender_identity_mismatch, _version}) do
    detail = "the sender identity is registered for another brand code"
    {:error, Gate.field_error("/brands", "conflict", detail)}
  end

  # PC-29
  # PC-34
  @doc "Tests the connection outside any transaction and answers what İYS said."
  @spec test(Scope.t()) :: answer()
  def test(%Scope{} = scope) do
    case Relay.Iys.test_connection(scope) do
      {:ok, report} ->
        body = Map.merge(%{"object" => "iys_connection_test"}, report)
        {:ok, {200, [], Map.put(body, "tested_at", Relay.Clock.utc_now())}}

      {:error, :not_configured} ->
        {:error, not_configured()}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # PC-30
  @doc "Reads the `state` filter of the upload list."
  @spec filters(map()) :: {:ok, String.t() | nil} | {:error, Relay.Error.t()}
  def filters(query) do
    case Map.get(query, "state") do
      state when state == nil or state in @states -> {:ok, state}
      _other -> {:error, Gate.field_error("/state", "unsupported_value", "unknown state")}
    end
  end

  # PC-30
  # API-56
  @doc "Lists uploads, newest first."
  @spec uploads(Scope.t(), String.t() | nil, Pagination.page(), String.t()) :: answer()
  def uploads(%Scope{} = scope, state, page, endpoint) do
    view = &upload_view/1

    case Relay.Iys.list_uploads(scope, state, page.cursor, page.limit) do
      {:ok, rows} ->
        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, view, &position/1),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  defp position(row), do: {row["cursor_at"], row["id"]}

  # PC-29
  @doc "The API view of a configuration with its brands; never the password or its reference text."
  @spec view(map(), [map()]) :: map()
  def view(config, brands) do
    %{
      "object" => "iys_config",
      "mode" => config["mode"],
      "api" => config["api"],
      "iys_code" => config["iys_code"],
      "integrator_code" => config["integrator_code"],
      "username" => config["username"],
      "credential_ref_id" => Views.id("sec", config["credential_ref_id"]),
      "brands" => Enum.map(brands, &brand_view/1),
      "quota" => %{
        "state" => config["quota_state"],
        "consent_limit" => config["consent_limit"],
        "used_consent_limit" => config["used_consent_limit"],
        "checked_at" => config["quota_checked_at"]
      },
      "blocked_code" => config["blocked_code"],
      "blocked_at" => config["blocked_at"],
      "version" => config["version"],
      "created_at" => config["created_at"],
      "updated_at" => config["updated_at"]
    }
  end

  # PC-29
  @doc "The API view of a brand: its binding and the access İYS gives by channel."
  @spec brand_view(map()) :: map()
  def brand_view(brand) do
    %{
      "object" => "iys_brand",
      "brand_code" => brand["brand_code"],
      "name" => brand["name"],
      "subtenant_id" => Views.id("stn", brand["subtenant_id"]),
      "sender_identity_id" => Views.id("snd", brand["sender_identity_id"]),
      "access" => %{
        "sms" => brand["message_access"],
        "voice" => brand["call_access"],
        "email" => brand["email_access"]
      },
      "authorised_at" => brand["authorised_at"]
    }
  end

  # PC-30
  @doc "The API view of an upload: no address, only its recipient when Relay knows one."
  @spec upload_view(map()) :: map()
  def upload_view(upload) do
    described = Relay.Iys.describe(upload)

    %{
      "object" => "iys_upload",
      "id" => Views.id("iyu", upload["id"]),
      "brand_code" => upload["brand_code"],
      "channel" => described.channel,
      "status" => described.status,
      "recipient_id" => Views.id("sub", upload["recipient_id"]),
      "origin" => upload["origin"],
      "state" => upload["state"],
      "consent_at" => upload["consent_at"],
      "deadline_at" => upload["deadline_at"],
      "attempts" => upload["attempts"],
      "error_code" => upload["error_code"],
      "error_at" => upload["error_at"],
      "transaction_ref" => upload["transaction_ref"],
      "registered_at" => upload["registered_at"],
      "trace_ref" => upload["trace_ref"],
      "created_at" => upload["created_at"],
      "settled_at" => upload["settled_at"]
    }
  end

  defp not_configured,
    do: Relay.Error.new(:iys_not_configured, "this environment has no İYS configuration")

  defp no_secret,
    do: Gate.field_error("/credential_ref_id", "not_found", "no active İYS credential")

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
