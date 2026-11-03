defmodule RelayWeb.Api.Level do
  @moduledoc """
  The level a template, layout, partial or brand request addresses: the sub-tenant an API client is bound to, else the `subtenant` query parameter, else the tenant level (`nil`). A malformed `subtenant` is the error the operation answers for it.
  """

  # TP-36
  @doc "The sub-tenant of a request, `nil` for the tenant level, or `error` for a malformed identifier."
  @spec subtenant(Plug.Conn.t(), Relay.Error.t()) ::
          {:ok, Relay.Id.t() | nil} | {:error, Relay.Error.t()}
  def subtenant(conn, error) do
    case conn.assigns.principal.subtenant_id do
      nil -> query(conn.query_params["subtenant"], error)
      bound -> {:ok, bound}
    end
  end

  defp query(nil, _error), do: {:ok, nil}

  defp query(text, error) when is_binary(text) do
    case Relay.ExternalId.decode(text, ["stn"]) do
      {:ok, id} -> {:ok, id}
      {:error, _reason} -> {:error, error}
    end
  end

  defp query(_other, error), do: {:error, error}

  @doc "The validation error of a malformed `subtenant` query parameter."
  @spec invalid() :: Relay.Error.t()
  def invalid do
    Relay.Error.new(:validation_failed, "the request breaks a field rule", %{
      errors: [%{pointer: "/subtenant", code: "invalid_format", detail: "not a subtenant id"}]
    })
  end
end
