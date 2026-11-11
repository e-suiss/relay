defmodule Relay.EmailReputation.Store do
  @moduledoc """
  Data access of the e-mail reputation circuits (CH-87) through `relay_fn.email_reputation_transition` and `relay_fn.email_reputation_close`. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @columns "tenant_id, environment, domain, state, rates, warned_at, stopped_at, closed_at, version, updated_at"

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # CH-87
  @doc "The circuit of a sending domain, `nil` when it never left `ok`."
  @spec circuit(String.t()) :: map() | nil
  def circuit(domain) do
    "SELECT #{@columns} FROM relay.email_reputation_circuits WHERE domain = $1"
    |> all([domain])
    |> List.first()
  end

  # CH-87
  @doc "Every circuit of the established scope, by domain."
  @spec circuits() :: [map()]
  def circuits do
    all("SELECT #{@columns} FROM relay.email_reputation_circuits ORDER BY domain", [])
  end

  # CH-41
  # CH-87
  @doc "Moves a circuit to `state` with the window's `rates`; a stopped circuit is never moved."
  @spec transition(String.t(), String.t(), map()) :: :changed | :unchanged
  def transition(domain, state, rates) do
    [row] = Repo.call!("relay_fn.email_reputation_transition", [domain, state, rates])
    Repo.code!(row["email_reputation_transition"], [:changed, :unchanged])
  end

  # CH-41
  # CH-87
  @doc "Closes a stopped circuit, audited."
  @spec close(String.t(), String.t(), <<_::256>>, Actor.t()) ::
          :closed | :not_stopped | :not_found
  def close(domain, reason, digest, %Actor{} = actor) do
    params = [domain, reason, digest | Actor.params(actor)]
    [row] = Repo.call!("relay_fn.email_reputation_close", params)
    Repo.code!(row["email_reputation_close"], [:closed, :not_stopped, :not_found])
  end

  defp all(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
