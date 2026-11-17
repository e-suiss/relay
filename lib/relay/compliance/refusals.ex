defmodule Relay.Compliance.Refusals do
  @moduledoc """
  Refusals on a running node (PC-35, PC-36, PC-38, PC-39, PC-61, INV-18): it applies a described refusal (`Relay.Compliance.refuse/2`, configured as `config :relay, Relay.Compliance, refusals: Relay.Compliance.Refusals`) and it issues and reads the one-click unsubscribe links of bulk e-mail.

  A refusal is applied at once and in one transaction (`relay_fn.refusal_apply`): the refusal record with its sealed evidence, what its scope writes (a preference for a `category` exit; the consent copy `REVOKED` with writer `relay` for a refusal notice, on the refusal's channel and, for an `all_channel` one, on every channel it covers, each with a refusal record of its own), the tenant events (`subscription.unsubscribed` and `preference.changed` for an exit, `consent.revoked` for a notice, `sms.opted_out` for a refusal on SMS that came from a keyword or the provider's opt-out) in the outbox and, for a refusal notice, the job that hands it to the refusal sink (`Relay.Compliance.Refusals.SinkWorker`). Nothing leaves Relay inside that transaction. The evidence (source, time, requesting address and user agent) is sealed under the recipient's `commercial_consent` subject key before the transaction opens. The request's reference makes a repeat harmless: the refusal is applied again, so a recipient who came back in between is out again, and it is recorded and announced once.

  An unsubscribe link carries a `Relay.Compliance.UnsubscribeToken`. Applying it takes the recipient out of the category of the message it came with, as a preference written by `unsubscribe`; it is never written to the commercial message registry (PC-35). The link's page offers one more step, a refusal notice for every marketing e-mail of the brand (PC-36). A link is invalid when its token does not verify or is on the revocation list, when its recipient is not active or when its category is not a commercial or bulk one.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Compliance, Relay.Preferences, Relay.Tenancy],
    exports: []

  @behaviour Relay.Compliance

  alias Relay.Compliance.Refusal
  alias Relay.Compliance.Refusals.SinkWorker
  alias Relay.Compliance.Refusals.Store
  alias Relay.Compliance.RefusalSink
  alias Relay.Redacted
  alias Relay.Scope

  @bulk ~w(marketing social)
  @unknown [:recipient_not_found, :recipient_deleted, :not_found]
  @kinds %{"email" => "email", "sms" => "phone", "voice" => "phone", "whatsapp" => "phone"}
  @link_sources %{rfc8058: "rfc8058", confirmation_page: "unsubscribe_link", mailto: "mailto"}
  @mailto_subject ~r/\Aunsubscribe:([A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+)\z/

  @type link :: %{
          locale: String.t() | nil,
          state: :open | :unsubscribed | :refused,
          category: String.t()
        }
  @type evidence :: %{
          required(:source) => :rfc8058 | :confirmation_page | :mailto,
          required(:at) => DateTime.t(),
          optional(:ip) => Redacted.t() | nil,
          optional(:user_agent) => Redacted.t() | nil
        }

  # PC-38
  # PC-39
  # PC-61
  # INV-18
  @impl Relay.Compliance
  def apply_refusal(%Scope{} = scope, %Refusal{} = refusal) do
    with {:ok, sealed} <- seal(scope, refusal) do
      applied(Store.in_scope(scope, fn _status -> write(scope, refusal, sealed) end))
    end
  end

  defp write(scope, refusal, sealed) do
    first = write_one(scope, refusal, sealed)
    Enum.each(refusal.covers, &write_one(scope, covered(refusal, &1), sealed))
    first
  end

  defp write_one(scope, refusal, sealed) do
    {code, refusal_id} = Store.apply_refusal(Relay.Id.generate(), refusal, sealed)
    if queued?(refusal, code), do: Store.insert_job!(SinkWorker.job(scope, refusal_id))
    {code, refusal_id}
  end

  # PC-61
  defp covered(refusal, channel),
    do: %{refusal | channel: channel, ref: String.slice(refusal.ref <> ":" <> channel, 0, 256)}

  defp queued?(refusal, code),
    do: Refusal.forwarded?(refusal) and code in [:applied, :reapplied]

  defp applied({:ok, {code, <<_::128>> = id}}) when code in [:applied, :reapplied, :exists],
    do: {:ok, %{result: code, refusal_id: id}}

  defp applied({:ok, {code, _id}})
       when code in [:recipient_not_found, :subtenant_not_found, :category_not_found],
       do: {:error, Relay.Error.new(:not_found, "the refusal names nothing Relay knows")}

  defp applied({:ok, {:not_allowed, _id}}),
    do: {:error, Relay.Error.new(:validation_failed, "the category cannot be left")}

  defp applied(_failed),
    do: {:error, Relay.Error.new(:service_unavailable, "the refusal is not applied")}

  # PC-35
  defp seal(scope, refusal) do
    evidence = evidence(refusal)

    with {:ok, sealed} <-
           Relay.Preferences.seal_refusal_evidence(scope, refusal.recipient_id, evidence),
         {:ok, consent_ct} <- consent_evidence(scope, refusal, evidence) do
      {:ok, Map.put(sealed, :consent_ct, consent_ct)}
    else
      {:error, %Relay.Error{code: code}} when code in @unknown ->
        {:error, Relay.Error.new(:not_found, "the refusal names nothing Relay knows")}

      _failed ->
        {:error, Relay.Error.new(:service_unavailable, "the evidence is not sealed")}
    end
  end

  defp consent_evidence(scope, refusal, evidence) do
    if Refusal.notice?(refusal) do
      with {:ok, sealed} <-
             Relay.Preferences.seal_consent_evidence(scope, refusal.recipient_id, evidence),
           do: {:ok, sealed.evidence_ct}
    else
      {:ok, nil}
    end
  end

  defp evidence(refusal) do
    %{
      "source" => refusal.source,
      "scope" => refusal.scope,
      "at" => DateTime.to_iso8601(refusal.occurred_at),
      "ref" => refusal.ref,
      "ip" => exposed(refusal.ip),
      "user_agent" => exposed(refusal.user_agent)
    }
  end

  defp exposed(nil), do: nil
  defp exposed(value), do: value |> Redacted.expose() |> to_string() |> String.slice(0, 512)

  defp current_address(scope, recipient_id, channel) do
    kind = Map.get(@kinds, channel)

    field = %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: recipient_id,
      retention_class: :recipient_profile,
      table: "recipient_addresses",
      column: "address_ct"
    }

    with true <- is_binary(kind),
         {:ok, ct} when is_binary(ct) <-
           Store.in_scope(scope, fn _status -> Store.address(recipient_id, kind) end),
         {:ok, address} <- Relay.Tenancy.decrypt_field(field, ct) do
      {:ok, address}
    else
      _none -> :none
    end
  end

  # PC-38
  @doc "Hands an applied refusal notice to the refusal sink, outside any transaction: `:ok` when the sink took it or there is nothing to hand over (the refusal or the recipient's address is gone), otherwise the sink's error."
  @spec forward(Scope.t(), Relay.Id.t()) :: :ok | {:error, term()}
  def forward(%Scope{} = scope, refusal_id) do
    case Store.in_scope(scope, fn _status -> Store.refusal(refusal_id) end) do
      {:ok, %{"scope" => "category"}} -> :ok
      {:ok, %{} = row} -> forward_row(scope, row)
      {:ok, nil} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp forward_row(scope, row) do
    case current_address(scope, row["recipient_id"], row["channel"]) do
      {:ok, address} ->
        RefusalSink.sink().refused(scope, %{
          brand: row["brand_subtenant_id"],
          channel: row["channel"],
          address: address,
          recipient_type: row["legal_type"],
          source: row["source"],
          occurred_at: row["occurred_at"]
        })

      :none ->
        :ok
    end
  end

  # PC-35
  # CH-38
  @doc "The unsubscribe URIs of a bulk e-mail to a recipient in a category: the HTTPS one-click URI under `root`, Relay's public root, on the page's self-explanatory path for `locale`, and the `mailto:` URI of the configured unsubscribe mailbox with the token in its subject. Reaches the key store, so it never runs inside a transaction."
  @spec links(Scope.t(), map()) ::
          {:ok, %{https: String.t(), mailto: String.t()}} | {:error, Relay.Error.t()}
  def links(%Scope{} = scope, %{recipient_id: recipient_id, category: category} = to) do
    claims = %{
      scope: scope,
      id: Relay.Id.generate(),
      recipient_id: recipient_id,
      category: category,
      channel: "email",
      brand_subtenant_id: Map.get(to, :brand_subtenant_id)
    }

    with {:ok, token} <- Relay.Compliance.issue_unsubscribe_token(claims) do
      mailbox = Relay.Compliance.config(:unsubscribe_mailbox, "unsubscribe@localhost")
      root = String.trim_trailing(Map.fetch!(to, :root), "/")

      {:ok,
       %{
         https: root <> path(Map.get(to, :locale)) <> token,
         mailto: "mailto:" <> mailbox <> "?subject=unsubscribe:" <> token
       }}
    end
  end

  # X-22
  @doc "The path of the unsubscribe page for a locale, ending in `/`."
  @spec path(String.t() | nil) :: String.t()
  def path("tr" <> _rest), do: "/abonelik-iptali/"
  def path(_locale), do: "/unsubscribe/"

  # PC-35
  # PC-36
  @doc "Describes an unsubscribe link without changing anything: the locale of its recipient, its category and whether the recipient is still in (`:open`), out of the category (`:unsubscribed`) or has refused the brand's commercial e-mail (`:refused`)."
  @spec describe_link(term()) :: {:ok, link()} | {:error, :invalid | :unavailable}
  def describe_link(token) do
    with {:ok, claims} <- Relay.Compliance.verify_unsubscribe_token(token), do: read(claims)
  end

  defp read(claims) do
    result =
      Store.in_scope(claims.scope, fn _status ->
        case Store.link(claims.recipient_id, claims.category, claims.channel, claims.id) do
          nil -> nil
          row -> Map.put(row, "refused", refused?(claims))
        end
      end)

    case result do
      {:ok, %{"revoked" => false, "message_class" => class} = row} when class in @bulk ->
        {:ok, %{locale: row["locale"], state: state(row), category: claims.category}}

      {:ok, _invalid} ->
        {:error, :invalid}

      {:error, %Relay.Error{code: :not_found}} ->
        {:error, :invalid}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp refused?(claims) do
    Enum.any?(Store.consents(claims.recipient_id), fn consent ->
      consent["brand_subtenant_id"] == claims.brand_subtenant_id and
        consent["channel"] == claims.channel and consent["status"] == "revoked"
    end)
  end

  defp state(%{"refused" => true}), do: :refused
  defp state(%{"preference" => "opt_out"}), do: :unsubscribed
  defp state(_row), do: :open

  # PC-35
  # INV-18
  @doc "Applies an unsubscribe link: the recipient leaves the category of the link's message on its channel, as a preference. Applying an applied link is `:ok` again."
  @spec apply_link(term(), evidence()) :: :ok | {:error, :invalid | :unavailable}
  def apply_link(token, %{source: source} = evidence) when is_map_key(@link_sources, source) do
    with {:ok, claims} <- Relay.Compliance.verify_unsubscribe_token(token),
         {:ok, _link} <- read(claims) do
      claims
      |> request(Map.fetch!(@link_sources, source), evidence)
      |> Map.put(:category, claims.category)
      |> refuse(claims)
    end
  end

  # PC-36
  # PC-38
  # PC-39
  @doc "Applies the second step of an unsubscribe link's page: a refusal notice for every marketing e-mail of the link's brand."
  @spec refuse_link(term(), map()) :: :ok | {:error, :invalid | :unavailable}
  def refuse_link(token, evidence) do
    with {:ok, claims} <- Relay.Compliance.verify_unsubscribe_token(token),
         {:ok, _link} <- read(claims) do
      claims |> request("unsubscribe_page", evidence) |> refuse(claims)
    end
  end

  defp request(claims, source, evidence) do
    scope = Relay.Compliance.default_scope(source)

    %{
      recipient_id: claims.recipient_id,
      channel: claims.channel,
      source: source,
      scope: scope,
      brand_subtenant_id: claims.brand_subtenant_id,
      ref: "token:" <> Relay.Id.to_string(claims.id) <> ":" <> scope,
      occurred_at: evidence.at,
      evidence: %{ip: Map.get(evidence, :ip), user_agent: Map.get(evidence, :user_agent)}
    }
  end

  defp refuse(attrs, claims) do
    case Relay.Compliance.refuse(claims.scope, attrs) do
      {:ok, _applied} ->
        :ok

      {:error, %Relay.Error{code: code}} when code in [:not_found, :validation_failed] ->
        {:error, :invalid}

      {:error, _error} ->
        {:error, :unavailable}
    end
  end

  # PC-35
  @doc "Applies the unsubscribe request of an inbound e-mail sent to the `mailto:` URI of a bulk e-mail: its subject carries the token, and the result is that of the one-click request. A message without a token is `:invalid`."
  @spec mailto(String.t(), DateTime.t()) :: :ok | {:error, :invalid | :unavailable}
  def mailto(subject, %DateTime{} = at) when is_binary(subject) do
    case Regex.run(@mailto_subject, String.trim(subject)) do
      [_all, token] -> apply_link(token, %{source: :mailto, at: at})
      nil -> {:error, :invalid}
    end
  end

  # PC-35
  @doc "Revokes an unsubscribe link by its token, so it is invalid from now on; revoking a revoked link is `:ok` again."
  @spec revoke_link(term(), String.t(), String.t()) :: :ok | {:error, :invalid | :unavailable}
  def revoke_link(token, reason, actor_ref) when is_binary(reason) and is_binary(actor_ref) do
    with {:ok, claims} <- Relay.Compliance.verify_unsubscribe_token(token) do
      revoke = fn _status -> Store.revoke(claims.id, reason, actor_ref) end

      case Store.in_scope(claims.scope, revoke) do
        {:ok, _revoked} -> :ok
        {:error, %Relay.Error{code: :not_found}} -> {:error, :invalid}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  end
end
