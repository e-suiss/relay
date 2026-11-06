defmodule Relay.Channels.Live.SettingsCheck do
  @moduledoc """
  The provider settings check job (CH-14, CH-52). A verification asked for a provider account (`Relay.Channels.Live.request_settings_check/3`) queues this job in the same transaction; the job reads the account, its credential from the secret backend for this call only (TN-26), runs the adapter's settings check and applies what the outcome leads to (`Relay.Channels.SettingsCheck.plan/3`) in one transaction. A provider that cannot be asked, or a credential that cannot be read, is tried again by the job queue (T-26); once the attempts are spent the account fails with `channel.provider_check_unavailable`. Its arguments carry identifiers only (T-15).

  `sweep/3` is the periodic check of the verified accounts (`Relay.Channels.Live.SettingsSweep`): a mismatch drops an account from the verified route, and a success never verifies one again.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 5, timeout: 60_000

  alias Relay.Channels.Live.Store
  alias Relay.Scope

  @actor_ref "relay"
  @call_ms 5_000

  @type result :: :ok | {:retry, String.t()} | {:error, term()}

  # T-15
  @doc "The job changeset that verifies a provider account."
  @spec job(Scope.t(), Relay.Id.t()) :: Ecto.Changeset.t()
  def job(%Scope{} = scope, account_id) do
    scope
    |> Scope.to_job_args()
    |> Map.put("provider_account_id", Relay.Id.to_string(account_id))
    |> new()
  end

  # CH-14
  # CH-52
  # T-26
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider_account_id" => text} = args} = job) do
    with {:ok, scope} <- Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(text),
         {:ok, %{} = account} <- Relay.Channels.provider_account(scope, id) do
      case check(scope, account, :verify, job.attempt >= job.max_attempts) do
        {:retry, reason} -> {:error, reason}
        result -> result
      end
    else
      {:ok, nil} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # CH-14
  # CH-52
  # INV-43
  @doc "Checks the settings of one provider account in a mode and applies the outcome; `final?` says that no attempt follows. `{:retry, reason}` asks the job queue for another attempt."
  @spec check(Scope.t(), map(), :verify | :recheck, boolean()) :: result()
  def check(%Scope{} = scope, %{} = account, mode, final?) do
    plan = Relay.Channels.settings_check_plan(mode, outcome(scope, account), final?)
    if plan.retry, do: {:retry, "provider_unavailable"}, else: apply_plan(scope, account, plan)
  end

  defp apply_plan(scope, %{"id" => id} = account, plan) do
    state = if plan.verification, do: elem(plan.verification, 0), else: "checked"
    digest = digest(scope, id, state)

    case Relay.Channels.apply_settings_check(scope, account, plan, digest, actor()) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp outcome(scope, account) do
    with true <- account["provider"] in Relay.Channels.settings_check_providers(),
         {:ok, credentials} <- credentials(scope, account) do
      Relay.Channels.check_settings(account, credentials, @call_ms)
    else
      false -> :unsupported
      {:error, reason} -> {:error, reason}
    end
  end

  # TN-26
  defp credentials(_scope, %{"credential_ref_id" => nil}), do: {:ok, nil}

  defp credentials(scope, %{"credential_ref_id" => ref_id}) do
    case Relay.Secrets.fetch(scope, ref_id) do
      {:ok, secret} -> {:ok, secret}
      {:error, _error} -> {:error, "credential_unavailable"}
    end
  end

  # CH-52
  # TN-13 (4)
  @doc "Checks the verified accounts whose settings check is due, at most `accounts` in each of at most `scopes` scopes; answers how many checks were applied."
  @spec sweep(pos_integer(), pos_integer(), pos_integer()) :: non_neg_integer()
  def sweep(interval_s, scopes, accounts) do
    providers = Relay.Channels.settings_check_providers()

    for {tenant_id, environment} <-
          Relay.Channels.settings_check_scopes(providers, interval_s, scopes),
        {:ok, scope} <- [Scope.new(tenant_id, environment)],
        {:ok, due} <- [Relay.Channels.settings_check_due(scope, providers, interval_s, accounts)],
        account <- due,
        check(scope, account, :recheck, true) == :ok,
        reduce: 0 do
      count -> count + 1
    end
  end

  # CH-14
  # CH-52
  @doc "Asks for the verification of a provider account inside the caller's scoped transaction: an unverified account becomes `pending` (audited) and the check job is queued in the same transaction; a verified account keeps its traffic until the check says otherwise."
  @spec request(Scope.t(), Relay.Id.t(), Relay.Actor.t()) :: :pending | :verified | :not_found
  def request(%Scope{} = scope, id, %Relay.Actor{} = actor) do
    case Relay.Channels.request_settings_check(id, digest(scope, id, "pending", actor), actor) do
      :not_found ->
        :not_found

      state ->
        :ok = Store.insert_job!(job(scope, id))
        state
    end
  end

  defp digest(scope, id, reason, actor \\ actor()) do
    Relay.Audit.record_digest(%{
      tenant_id: scope.tenant_id,
      environment: Relay.Environment.dump(scope.environment),
      action: "provider_account.verified",
      actor_kind: Atom.to_string(actor.kind),
      actor_ref: actor.ref,
      on_behalf_of_ref: actor.on_behalf_of_ref,
      access_record_ref: actor.access_record_ref,
      target_type: "provider_account",
      target_id: Relay.Id.to_string(id),
      reason: reason
    })
  end

  defp actor do
    {:ok, actor} = Relay.Actor.new(:system, @actor_ref, @actor_ref)
    actor
  end
end
