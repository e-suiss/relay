defmodule Relay.Subscribers do
  @moduledoc """
  Subscribers (C-19, C-20, API-21, API-66): recipients of kind `subscriber`, unique per tenant environment by their external identifier, which is stored encrypted and found through its blind index. Profile fields and addresses are encrypted under the subscriber's `recipient_profile` data key, so erasing the subject destroys them by crypto-shredding; rows are never deleted.

  A write happens in two parts. `prepare/3` runs outside any transaction: it computes the blind indexes, looks the subscriber up, takes its data key (or generates one for a new subscriber) and encrypts the fields. `upsert/2` runs inside the caller's scoped transaction and calls the single write path `relay_fn.recipient_upsert` in one of its modes: `create`, `replace`, `patch`, `implicit` (a send's recipient object with contact details), `inbox_only` (a send's `{id}` object) and `require` (a send's plain identifier, which never creates a subscriber).
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Tenancy, Relay.Keys.Erasure], exports: []

  alias Relay.Actor
  alias Relay.Scope
  alias Relay.Subscribers.Erasure
  alias Relay.Subscribers.Profile
  alias Relay.Subscribers.Store

  @system %Actor{
    kind: :system,
    ref: "relay:subscriber_erasure",
    on_behalf_of_ref: "relay:subscriber_erasure"
  }

  @type mode :: :create | :replace | :patch | :implicit | :inbox_only | :require
  @type input :: %{external_id: String.t(), fields: %{optional(String.t()) => term()}}
  @type plan :: map()

  # C-19
  # C-20
  # API-21
  # TN-33
  @doc "Prepares a subscriber write outside any transaction: blind indexes, the lookup, the data key and the encrypted fields of `input`. `fields` holds only the fields the request names; `nil` clears one."
  @spec prepare(Scope.t(), input(), mode(), keyword()) :: {:ok, plan()} | {:error, term()}
  def prepare(%Scope{} = scope, %{external_id: external_id, fields: fields}, mode, opts \\ []) do
    with {:ok, {bidx_key_id, bidx}} <- index(scope, "external_id", external_id),
         {:ok, existing} <- Store.in_scope(scope, fn _status -> Store.lookup(bidx) end) do
      base =
        Map.merge(empty(), %{
          mode: mode,
          bidx: bidx,
          bidx_key_id: bidx_key_id,
          external_id: external_id,
          existing: existing
        })

      with {:ok, plan} <- plan(scope, base, fields, existing),
           do: {:ok, %{plan | masked: view(scope, existing, Keyword.get(opts, :view, false))}}
    end
  end

  defp view(scope, existing, true), do: masked(scope, existing)
  defp view(_scope, _existing, false), do: %{}

  defp masked(scope, %{"id" => id, "kind" => "subscriber"}) do
    case Store.in_scope(scope, fn _status -> Store.row(id) end) do
      {:ok, %{} = row} ->
        %{
          "email" => Profile.mask_email(open(scope, row, "addresses", "email_ct")),
          "name" => Profile.mask_name(open(scope, row, "recipients", "name_ct"))
        }

      _other ->
        %{}
    end
  end

  defp masked(_scope, _existing), do: %{}

  defp plan(_scope, %{mode: :require} = base, _fields, existing),
    do: {:ok, %{base | id: existing_id(existing)}}

  defp plan(_scope, %{mode: :inbox_only} = base, _fields, %{} = existing),
    do: {:ok, %{base | id: existing["id"]}}

  defp plan(_scope, base, _fields, %{"kind" => "agent"} = existing),
    do: {:ok, %{base | id: existing["id"]}}

  defp plan(scope, %{mode: mode} = base, fields, %{"state" => state} = existing)
       when mode != :create and state != "deleted" do
    id = existing["id"]

    with {:ok, key} <- Relay.Tenancy.data_key(field(scope, id, "recipients", "external_id_ct")) do
      encrypt(scope, %{base | id: id}, fields, key)
    end
  end

  defp plan(scope, base, fields, _existing) do
    id = Relay.Id.generate()

    with {:ok, wrapping_key_id} <- Relay.Tenancy.active_tenant_key(scope, :dek_wrap),
         {:ok, %{wrapped_dek: wrapped, data_key: key}} <-
           Relay.Tenancy.generate_subject_key(scope, wrapping_key_id, id, :recipient_profile),
         {:ok, external_id_ct} <-
           Relay.Tenancy.encrypt_field(
             field(scope, id, "recipients", "external_id_ct"),
             base.external_id,
             data_key: key
           ) do
      base = %{
        base
        | id: id,
          external_id_ct: external_id_ct,
          profile_dek_id: Relay.Id.generate(),
          wrapped_dek: wrapped,
          wrapping_key_id: wrapping_key_id
      }

      encrypt(scope, base, fields, key)
    end
  end

  defp existing_id(%{"id" => id}), do: id
  defp existing_id(nil), do: Relay.Id.generate()

  defp encrypt(scope, plan, fields, key) do
    named = Map.take(fields, Profile.fields())
    initial = {:ok, %{plan | fields: Map.keys(named)}}

    Enum.reduce_while(named, initial, fn {name, value}, {:ok, acc} ->
      case put_field(scope, acc, name, value, key) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp put_field(_scope, plan, "locale", value, _key), do: {:ok, %{plan | locale: value}}
  defp put_field(_scope, plan, "timezone", value, _key), do: {:ok, %{plan | timezone: value}}
  defp put_field(_scope, plan, "legal_type", value, _key), do: {:ok, %{plan | legal_type: value}}

  defp put_field(_scope, plan, "name", nil, _key),
    do: {:ok, %{plan | plain: Map.put(plan.plain, "name", nil)}}

  defp put_field(scope, plan, "name", name, key) do
    with {:ok, ct} <- seal(scope, plan.id, "recipients", "name_ct", name, key),
         do: {:ok, %{plan | name_ct: ct, plain: Map.put(plan.plain, "name", name)}}
  end

  defp put_field(_scope, plan, "attributes", nil, _key), do: {:ok, plan}

  defp put_field(scope, plan, "attributes", attributes, key) do
    json = Jason.encode!(attributes)

    with {:ok, ct} <- seal(scope, plan.id, "recipients", "attributes_ct", json, key),
         do: {:ok, %{plan | attributes_ct: ct}}
  end

  defp put_field(_scope, plan, kind, nil, _key) when kind in ["email", "phone"],
    do: {:ok, %{plan | plain: Map.put(plan.plain, kind, nil)}}

  defp put_field(scope, plan, kind, value, key) when kind in ["email", "phone"] do
    value = if kind == "email", do: Profile.email(value), else: value

    with {:ok, ct} <- seal(scope, plan.id, "recipient_addresses", "address_ct", value, key),
         {:ok, {bidx_key_id, bidx}} <- index(scope, "address", value) do
      plan = %{plan | address_bidx_key_id: bidx_key_id, plain: Map.put(plan.plain, kind, value)}

      {:ok,
       if kind == "email" do
         %{plan | email_address_id: Relay.Id.generate(), email_ct: ct, email_bidx: bidx}
       else
         %{plan | phone_address_id: Relay.Id.generate(), phone_ct: ct, phone_bidx: bidx}
       end}
    end
  end

  defp seal(scope, id, table, column, value, key),
    do: Relay.Tenancy.encrypt_field(field(scope, id, table, column), value, data_key: key)

  defp index(scope, purpose, value) do
    Relay.Tenancy.blind_index(
      %{tenant_id: scope.tenant_id, environment: scope.environment, purpose: purpose},
      value
    )
  end

  defp field(scope, id, table, column) do
    %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: id,
      retention_class: :recipient_profile,
      table: table,
      column: column
    }
  end

  defp empty do
    %{
      id: nil,
      mode: nil,
      bidx: nil,
      bidx_key_id: nil,
      external_id: nil,
      existing: nil,
      external_id_ct: nil,
      profile_dek_id: nil,
      wrapped_dek: nil,
      wrapping_key_id: nil,
      fields: [],
      name_ct: nil,
      attributes_ct: nil,
      locale: nil,
      timezone: nil,
      legal_type: nil,
      email_address_id: nil,
      email_ct: nil,
      email_bidx: nil,
      phone_address_id: nil,
      phone_ct: nil,
      phone_bidx: nil,
      address_bidx_key_id: nil,
      plain: %{},
      masked: %{}
    }
  end

  # API-21
  # API-66
  @doc "Writes a prepared subscriber inside the caller's scoped transaction; returns `{result, recipient_id, version}`."
  @spec upsert(plan(), pos_integer() | nil) :: {atom(), Relay.Id.t() | nil, pos_integer() | nil}
  defdelegate upsert(plan, expected_version), to: Store

  # API-66
  @doc "Reads a subscriber row inside the caller's scoped transaction, or `nil`."
  @spec row(Relay.Id.t()) :: map() | nil
  defdelegate row(id), to: Store

  # API-66
  @doc "Reads a subscriber by external identifier and describes it; `nil` when there is none."
  @spec fetch(Scope.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def fetch(%Scope{} = scope, external_id) do
    with {:ok, {_key_id, bidx}} <- index(scope, "external_id", external_id),
         {:ok, row} <- Store.in_scope(scope, fn _status -> found_row(Store.lookup(bidx)) end) do
      {:ok, row && describe(scope, row)}
    end
  end

  defp found_row(%{"id" => id, "kind" => "subscriber", "state" => state}) when state != "deleted",
    do: Store.row(id)

  defp found_row(_other), do: nil

  # API-56
  @doc "Lists subscribers from a decoded cursor and describes them; at most `limit + 1` come back."
  @spec list(Scope.t(), map() | nil, pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list(%Scope{} = scope, cursor, limit) do
    with {:ok, rows} <- Store.in_scope(scope, fn _status -> Store.list(cursor, limit) end) do
      {:ok, Enum.map(rows, &Map.put(describe(scope, &1), "_cursor_at", &1["created_at"]))}
    end
  end

  # X-5
  # API-66
  @doc "Describes a subscriber row for the API with masked personal fields and the reachability summary. Without `plan` the personal fields are decrypted, so call it outside any transaction; with the plan of a write, the values it already holds are used and nothing is decrypted."
  @spec describe(Scope.t(), map(), plan() | nil) :: map()
  def describe(%Scope{} = scope, row, plan \\ nil) do
    id = row["id"]

    {external_id, email, name} =
      case plan do
        nil ->
          {open(scope, row, "recipients", "external_id_ct"),
           Profile.mask_email(open(scope, row, "addresses", "email_ct")),
           Profile.mask_name(open(scope, row, "recipients", "name_ct"))}

        %{} ->
          {plan.external_id, known(plan, "email", &Profile.mask_email/1),
           known(plan, "name", &Profile.mask_name/1)}
      end

    %{
      "object" => "subscriber",
      "id" => Relay.ExternalId.encode("sub", id),
      "external_id" => external_id,
      "email" => email,
      "phone" => nil,
      "name" => name,
      "locale" => row["locale"],
      "timezone" => row["timezone"],
      "legal_type" => row["legal_type"],
      "channels" => Profile.channels(row["email_state"], row["phone_state"]),
      "state" => row["state"],
      "version" => row["version"],
      "created_at" => row["created_at"],
      "updated_at" => row["updated_at"],
      "_id" => id
    }
  end

  defp known(plan, name, mask) do
    if Map.has_key?(plan.plain, name),
      do: mask.(plan.plain[name]),
      else: Map.get(plan.masked, name)
  end

  defp open(scope, row, table, key) do
    case table do
      "addresses" -> decrypt(scope, row["id"], "recipient_addresses", "address_ct", row[key])
      table -> decrypt(scope, row["id"], table, key, row[key])
    end
  end

  defp decrypt(_scope, _id, _table, _column, nil), do: nil

  defp decrypt(scope, id, table, column, ct) do
    case Relay.Tenancy.decrypt_field(field(scope, id, table, column), ct) do
      {:ok, value} -> Relay.Redacted.expose(value)
      {:error, _error} -> nil
    end
  end

  # API-21
  @doc "The blind indexes of external identifiers, computed outside any transaction."
  @spec indexes(Scope.t(), [String.t()]) :: {:ok, [binary()]} | {:error, term()}
  def indexes(%Scope{} = scope, external_ids) do
    Enum.reduce_while(external_ids, {:ok, []}, fn external_id, {:ok, acc} ->
      case index(scope, "external_id", external_id) do
        {:ok, {_key_id, bidx}} -> {:cont, {:ok, [bidx | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  @doc "The subscribers of blind indexes, inside the caller's scoped transaction."
  @spec resolve_indexes([binary()]) :: [Relay.Id.t()]
  defdelegate resolve_indexes(bidxs), to: Store, as: :lookup_many

  # API-66
  @doc "Requests the deletion of a subscriber inside the caller's scoped transaction and queues its erasure job in the same transaction."
  @spec request_deletion(Scope.t(), Relay.Id.t(), <<_::256>>, Actor.t()) ::
          {:requested | :already_requested | :not_found | :held, map() | nil}
  def request_deletion(%Scope{} = scope, recipient_id, digest, %Actor{} = actor) do
    case Store.deletion_request(Relay.Id.generate(), recipient_id, digest, actor) do
      {:requested, request_id} ->
        :ok = Store.insert_job!(Erasure.job(scope, request_id, recipient_id))
        {:requested, Store.deletion(request_id)}

      {result, nil} ->
        {result, nil}

      {result, request_id} ->
        {result, Store.deletion(request_id)}
    end
  end

  # API-66
  # OP-24
  @doc "Carries out a deletion request: erases the subject and completes or holds the request."
  @spec erase(Scope.t(), Relay.Id.t(), Relay.Id.t()) :: {:ok, atom()} | {:error, term()}
  def erase(%Scope{} = scope, request_id, recipient_id) do
    ref = Relay.ExternalId.encode("sdr", request_id)

    case Relay.Keys.Erasure.erase_subject(scope, recipient_id, ref, @system) do
      {:ok, result, _cancelled} when result in [:erased, :already_erased] ->
        Store.in_scope(scope, fn _status ->
          Store.deletion_complete(request_id, Store.erasure_id(recipient_id))
        end)

      {:ok, _held_or_missing, _cancelled} ->
        Store.in_scope(scope, fn _status -> Store.deletion_complete(request_id, nil) end)

      {:error, error} ->
        {:error, error}
    end
  end
end
