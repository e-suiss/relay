defmodule Relay.Operators do
  @moduledoc """
  Operators of Relay: identity from Access, roles in Relay (TN-19 … TN-23, E-26, E-27, E-63, X-3).

  Relay keeps no users or passwords. An operator signs in through Access OpenID Connect (authorization code with PKCE); on the first sign-in Relay creates the operator record, keyed by the Access subject, and opens a session whose cookie value is stored only as a digest. The first installation operator is the Access subject configured as `config :relay, Relay.Operators, bootstrap_subject: sub`, assigned on its first sign-in while the installation has never had an installation operator; emergency access is Access break-glass. The CLI authenticates with an Access access token whose audience is the operator API.

  Sensitive operations need a step-up that is at most five minutes old and bound to the session, at the `acr` the installation configures; when Access offers the AuthZEN decision API, Access decides too (`config :relay, Relay.Operators, authzen: :when_offered | :required | :off`). Access that cannot be reached means the operation is not performed (`auth_step_up_unavailable`). Every audit record of an operator action carries the operator's Access subject and the Access record of its step-up or session (TN-48, E-31).

  The Access event consumer calls `Relay.Operators.AccessUserHandler` for the Access `user.*` events (TN-20) and `tenant_owner/2` for the owners named by `tenant.created` (API-79 (5)).
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Access, Relay.Audit, Relay.Datasets, Relay.Platform.Leadership],
    exports: [Access, Authz, Session, Admin, Suspension, SuspensionActivator, AccessUserHandler]

  require Logger

  alias Relay.Actor
  alias Relay.Operators.Access
  alias Relay.Operators.Authz
  alias Relay.Operators.Session
  alias Relay.Operators.Store
  alias Relay.Scope

  @step_up_window_s Relay.Limits.fetch!(["operator_step_up_window_seconds"])
  @step_up_start "/v1/operator/session/step_up"

  @doc "The validity of a step-up, in seconds."
  @spec step_up_window_s() :: pos_integer()
  def step_up_window_s, do: @step_up_window_s

  @doc "The installation tenant's identifier."
  @spec installation_tenant_id() :: Relay.Id.t()
  def installation_tenant_id, do: installation_scope().tenant_id

  @doc "The installation scope: the installation tenant's `live` environment."
  @spec installation_scope() :: Scope.t()
  def installation_scope, do: Relay.Datasets.installation_scope()

  # E-26
  @doc "Fresh login parameters: `state`, `nonce` and the PKCE `verifier` with its S256 `challenge`."
  @spec login_parameters() :: %{
          state: String.t(),
          nonce: String.t(),
          verifier: String.t(),
          challenge: String.t()
        }
  def login_parameters do
    verifier = token()

    %{
      state: token(),
      nonce: token(),
      verifier: verifier,
      challenge: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    }
  end

  @doc "A 256-bit random value, URL-safe Base64 without padding."
  @spec token() :: String.t()
  def token, do: Base.url_encode64(Relay.Random.bytes(32), padding: false)

  @doc "The SHA-256 digest of a session cookie value or CSRF token."
  @spec digest(String.t()) :: <<_::256>>
  def digest(value) when is_binary(value), do: :crypto.hash(:sha256, value)

  # TN-19
  # TN-20
  # E-63
  @doc """
  Completes a login: exchanges the code at Access, validates the ID token against the nonce, creates the operator on first sign-in, assigns the bootstrap installation operator and opens a session. Returns the cookie value and the CSRF token `csrf_of` derives from it; only their digests are stored.
  """
  @spec complete_login(String.t(), map(), String.t(), (String.t() -> String.t())) ::
          {:ok, %{token: String.t(), csrf: String.t(), session: Session.t()}}
          | {:error, Relay.Error.t()}
  def complete_login(code, %{verifier: verifier, nonce: nonce}, redirect_uri, csrf_of) do
    with {:ok, claims} <- Access.complete(code, verifier, redirect_uri, nonce),
         {:ok, subject} <- subject(claims),
         token = token(),
         csrf = csrf_of.(token),
         {:ok, operator_id} <- sign_in(claims, subject, token, csrf),
         :ok <- bootstrap(operator_id, subject),
         {:ok, session} <- resolve(token) do
      {:ok, %{token: token, csrf: csrf, session: session}}
    end
  end

  defp subject(%{"sub" => sub}) when is_binary(sub) and byte_size(sub) in 1..256, do: {:ok, sub}
  defp subject(_claims), do: {:error, Relay.Error.new(:auth_invalid_token, "no Access subject")}

  defp sign_in(claims, subject, token, csrf) do
    attrs = %{
      operator_id: Relay.Id.generate(),
      access_subject: subject,
      session_id: Relay.Id.generate(),
      token_digest: digest(token),
      csrf_digest: digest(csrf),
      client_kind: "panel",
      access_session_ref: claims["sid"],
      auth_time: claims["auth_time"] || Relay.Clock.utc_now(),
      acr: claims["acr"]
    }

    case Store.sign_in(attrs) do
      {result, operator_id, _session, _expires} when result in [:signed_in, :created] ->
        {:ok, operator_id}

      {_inactive, _operator_id, _session, _expires} ->
        {:error, Relay.Error.new(:auth_invalid_session, "the operator is not active in Access")}
    end
  end

  # TN-19
  defp bootstrap(operator_id, subject) do
    configured = Keyword.get(config(), :bootstrap_subject)

    if is_binary(configured) and configured == subject,
      do: assign_bootstrap(operator_id),
      else: :ok
  end

  defp assign_bootstrap(operator_id) do
    scope = installation_scope()
    actor = system_actor("system:bootstrap")

    case Store.in_scope(scope, &bootstrap_in(&1, scope, operator_id, actor)) do
      {:ok, _outcome} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp bootstrap_in(_status, scope, operator_id, actor) do
    if Store.installation_assigned?(),
      do: :skipped,
      else: assign(scope, operator_id, :installation_operator, "bootstrap", nil, actor)
  end

  defp assign(scope, operator_id, role, reason, step_up_ref, actor) do
    id = Relay.Id.generate()
    target = Relay.Id.to_string(id)

    digest =
      record_digest(scope, "role_assignment.created", actor, "role_assignment", target, reason)

    Store.role_assign(
      %{id: id, operator_id: operator_id, role: role, reason: reason, step_up_ref: step_up_ref},
      digest,
      actor
    )
  end

  @doc "Resolves a panel session from its cookie value; an unknown, expired or revoked session, or one of an operator Access suspended, is `auth_invalid_session`."
  @spec resolve(String.t()) :: {:ok, Session.t()} | {:error, Relay.Error.t()}
  def resolve(token) when is_binary(token) do
    case Store.resolve(digest(token)) do
      %{"state" => "active", "operator_status" => "active"} = row ->
        {:ok, session(row)}

      _other ->
        {:error, Relay.Error.new(:auth_invalid_session, "the operator session is not valid")}
    end
  end

  defp session(row) do
    operator = Store.operator(row["operator_id"])

    %Session{
      id: row["session_id"],
      operator_id: row["operator_id"],
      subject: operator["access_subject"],
      operator_created_at: operator["created_at"],
      client_kind: :panel,
      auth_time: row["auth_time"],
      acr: row["acr"],
      step_up_at: row["step_up_at"],
      step_up_ref: row["step_up_record_ref"],
      access_session_ref: nil,
      csrf_digest: row["csrf_digest"],
      expires_at: row["expires_at"],
      grants: grants(row["operator_id"])
    }
  end

  # TN-19
  @doc "Resolves the CLI's Access access token into a session; the operator is created on first use."
  @spec resolve_bearer(String.t()) :: {:ok, Session.t()} | {:error, Relay.Error.t()}
  def resolve_bearer(token) when is_binary(token) do
    with {:ok, claims} <- Access.verify_access_token(token),
         {:ok, subject} <- subject(claims) do
      case Store.ensure(Relay.Id.generate(), subject) do
        {_result, operator_id, "active"} ->
          operator = Store.operator(operator_id)

          {:ok,
           %Session{
             id: nil,
             operator_id: operator_id,
             subject: subject,
             operator_created_at: operator["created_at"],
             client_kind: :cli,
             auth_time: claims["auth_time"],
             acr: claims["acr"],
             step_up_at: claims["auth_time"],
             step_up_ref: claims["step_up_ref"],
             access_session_ref: claims["sid"],
             csrf_digest: nil,
             expires_at: claims["exp"],
             grants: grants(operator_id)
           }}

        {_result, _operator_id, _inactive} ->
          {:error, Relay.Error.new(:auth_invalid_token, "the operator is not active in Access")}
      end
    end
  end

  @doc "The active role grants of an operator."
  @spec grants(Relay.Id.t()) :: [Authz.grant()]
  def grants(operator_id) do
    for row <- Store.roles(operator_id),
        {:ok, environment} <- [Relay.Environment.cast(row["environment"])] do
      %{
        tenant_id: row["tenant_id"],
        environment: environment,
        role: role(row["role"]),
        role_assignment_id: row["role_assignment_id"]
      }
    end
  end

  @doc "Decodes a stored role name."
  @spec role(String.t()) :: Authz.role()
  def role("installation_operator"), do: :installation_operator
  def role("tenant_admin"), do: :tenant_admin
  def role("tenant_operator"), do: :tenant_operator

  # TN-23
  @doc "The active support delegation of an operator in a tenant scope, or nil."
  @spec delegation_active(Relay.Id.t(), Scope.t()) :: map() | nil
  def delegation_active(operator_id, %Scope{} = scope),
    do: Store.delegation_active(operator_id, scope)

  @doc "Signs a panel session out."
  @spec sign_out(Session.t()) :: :ok
  def sign_out(%Session{id: nil}), do: :ok

  def sign_out(%Session{id: id}) do
    _ = Store.revoke(id, "logout")
    :ok
  end

  # TN-21
  # E-27
  @doc """
  Records a completed step-up on a panel session. The ID token must belong to the session's operator, carry the configured `acr` and an authentication time inside the step-up window.
  """
  @spec complete_step_up(Session.t(), String.t(), map(), String.t()) ::
          :ok | {:error, Relay.Error.t()}
  def complete_step_up(%Session{} = session, code, %{verifier: verifier, nonce: nonce}, redirect) do
    with {:ok, claims} <- Access.complete(code, verifier, redirect, nonce),
         :ok <- same_operator(session, claims),
         :ok <- fresh_authentication(claims["auth_time"], claims["acr"]) do
      ref = claims["step_up_ref"] || claims["sid"] || "access:" <> session.subject

      case Store.step_up(session.id, claims["auth_time"], claims["acr"], ref) do
        :recorded ->
          :ok

        :session_inactive ->
          {:error, Relay.Error.new(:auth_invalid_session, "the session is not active")}
      end
    end
  end

  defp same_operator(session, %{"sub" => sub}) when sub == session.subject, do: :ok

  defp same_operator(_session, _claims),
    do: {:error, Relay.Error.new(:auth_invalid_token, "the step-up belongs to another operator")}

  defp fresh_authentication(%DateTime{} = auth_time, acr) do
    if within_window?(auth_time) and acr_satisfied?(acr),
      do: :ok,
      else: {:error, Relay.Error.new(:validation_failed, "the step-up is not recent enough")}
  end

  defp fresh_authentication(_auth_time, _acr),
    do: {:error, Relay.Error.new(:validation_failed, "the step-up has no authentication time")}

  # TN-21
  @doc "Returns true if the session's step-up is inside the window and at the required `acr`."
  @spec step_up_fresh?(Session.t()) :: boolean()
  def step_up_fresh?(%Session{step_up_at: %DateTime{} = at, step_up_ref: ref, acr: acr})
      when is_binary(ref),
      do: within_window?(at) and acr_satisfied?(acr)

  def step_up_fresh?(%Session{}), do: false

  defp within_window?(at) do
    age = DateTime.diff(Relay.Clock.utc_now(), at, :second)
    age >= -60 and age <= @step_up_window_s
  end

  defp acr_satisfied?(acr) do
    required = Access.step_up_acr()
    is_binary(acr) and required in String.split(acr, " ")
  end

  # TN-21
  # TN-22
  # E-27
  @doc """
  Checks the step-up of a sensitive operation, fail closed: a missing or stale step-up is `auth_step_up_required` with the challenge; then, unless AuthZEN is off, Access decides (`auth_insufficient_role` when it denies, `auth_step_up_unavailable` when it cannot answer). Returns the Access references the operation's audit record carries.
  """
  @spec step_up(Session.t(), String.t(), String.t()) ::
          {:ok, %{step_up_ref: String.t(), decision_ref: String.t() | nil}}
          | {:error, Relay.Error.t()}
  def step_up(%Session{} = session, action, resource) do
    if step_up_fresh?(session),
      do: decide(session, action, resource),
      else: {:error, step_up_required()}
  end

  @doc "The `auth_step_up_required` error with its RFC 9470 challenge."
  @spec step_up_required() :: Relay.Error.t()
  def step_up_required do
    Relay.Error.new(:auth_step_up_required, "this operation needs a fresh Access step-up", %{
      step_up: %{
        acr_values: Access.step_up_acr(),
        max_age: @step_up_window_s,
        start: @step_up_start
      }
    })
  end

  defp decide(session, action, resource) do
    mode = Keyword.get(config(), :authzen, :when_offered)
    refs = %{step_up_ref: session.step_up_ref, decision_ref: nil}
    request = %{subject: session.subject, action: action, resource: resource(resource)}

    case if(mode == :off, do: :off, else: Access.evaluate(request)) do
      :off ->
        {:ok, refs}

      :not_offered when mode == :when_offered ->
        {:ok, refs}

      :not_offered ->
        {:error, Access.unavailable("Access offers no decision API")}

      {:ok, %{decision: true, ref: ref}} ->
        {:ok, %{refs | decision_ref: ref}}

      {:ok, %{decision: false}} ->
        {:error, Relay.Error.new(:auth_insufficient_role, "Access denied the operation")}

      {:error, error} ->
        Logger.warning("Access decision unavailable; the operation is refused", code: error.code)
        {:error, Access.unavailable()}
    end
  end

  defp resource(resource), do: %{type: "relay_resource", id: resource}

  # TN-48
  # E-31
  @doc """
  The audit actor of an operator action: the operator's Access subject, on its own behalf or on behalf of a support delegation, with the Access record the action relies on (its step-up when it needed one, else its Access session).
  """
  @spec actor(Session.t(), keyword()) :: Actor.t()
  def actor(%Session{} = session, opts \\ []) do
    kind = if Keyword.get(opts, :installation, false), do: :installation_operator, else: :operator

    on_behalf_of =
      case Keyword.get(opts, :delegation) do
        nil -> session.subject
        id -> Relay.ExternalId.encode("dlg", id)
      end

    record =
      Keyword.get(opts, :access_record_ref) || session.access_session_ref ||
        if(session.id, do: Relay.ExternalId.encode("oss", session.id))

    {:ok, actor} = Actor.new(kind, session.subject, on_behalf_of, record)
    actor
  end

  # TN-20
  @doc """
  Reflects an Access user lifecycle event on the operator with that Access subject: `:suspended` and `:deleted` revoke every active session at once (audited as `operator_session.revoked`), `:deleted` also clears the stored personal fields; `:active` reactivates. Roles stay in Relay. Called by the Access event intake with the event's `webhook-id`.
  """
  @spec access_user_changed(String.t(), :active | :suspended | :deleted, String.t() | nil) ::
          {:ok,
           %{result: :changed | :unchanged | :not_found, revoked_sessions: non_neg_integer()}}
  def access_user_changed(subject, status, event_ref)
      when is_binary(subject) and status in [:active, :suspended, :deleted] do
    {:ok, actor} = Actor.new(:access, "access", subject, event_ref)
    scope = installation_scope()
    text = Atom.to_string(status)
    digest = record_digest(scope, "operator_session.revoked", actor, "operator", subject, text)
    {result, revoked} = Store.set_status(subject, text, event_ref, digest, actor)
    {:ok, %{result: result, revoked_sessions: revoked}}
  end

  # API-79 (5)
  @doc """
  Makes an Access tenant owner the tenant's administrator in both environments, creating the operator record if the owner has not signed in yet; an existing administrator assignment is kept. Called by the Access event intake for the owners `tenant.created` names.
  """
  @spec tenant_owner(Relay.Id.t(), String.t()) :: :ok | {:error, Relay.Error.t()}
  def tenant_owner(tenant_id, subject) when is_binary(subject) do
    case Store.ensure(Relay.Id.generate(), subject) do
      {_result, operator_id, "active"} ->
        actor = system_actor("access:tenant.created")
        Enum.reduce_while([:live, :test], :ok, &owner_in(tenant_id, operator_id, actor, &1, &2))

      {_result, _operator_id, _inactive} ->
        {:error, Relay.Error.new(:operator_inactive, "the owner is not active in Access")}
    end
  end

  defp owner_in(tenant_id, operator_id, actor, environment, :ok) do
    scope = Scope.new!(tenant_id, environment)

    work = fn _status ->
      assign(scope, operator_id, :tenant_admin, "Access tenant owner", nil, actor)
    end

    case Store.in_scope(scope, work) do
      {:ok, {result, _id}} when result in [:assigned, :exists] -> {:cont, :ok}
      {:ok, {result, _id}} -> {:halt, {:error, Relay.Error.new(result, "not assigned")}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  @doc "A system actor."
  @spec system_actor(String.t()) :: Actor.t()
  def system_actor(ref) do
    {:ok, actor} = Actor.new(:system, ref, ref)
    actor
  end

  @doc "The record digest of an audit record an operator function writes."
  @spec record_digest(
          Scope.t(),
          String.t(),
          Actor.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) ::
          <<_::256>>
  def record_digest(%Scope{} = scope, action, %Actor{} = actor, target_type, target_id, reason) do
    Relay.Audit.record_digest(%{
      tenant_id: scope.tenant_id,
      environment: Relay.Environment.dump(scope.environment),
      action: action,
      actor_kind: Atom.to_string(actor.kind),
      actor_ref: actor.ref,
      on_behalf_of_ref: actor.on_behalf_of_ref,
      access_record_ref: actor.access_record_ref,
      target_type: target_type,
      target_id: target_id,
      reason: reason
    })
  end

  @doc "The operator surface configuration."
  @spec config() :: keyword()
  def config, do: Application.get_env(:relay, __MODULE__, [])
end
