defmodule RelayDev.Seed do
  @moduledoc """
  Sample data of the local environment (T-65 (1)): a sample tenant with its `live` and `test` environments and keys, a recipient in the test plane, the bundled data set versions, the link to the local Access stand-in (`RelayDev.Access`), a test plane API client trace with every server scope and a published `welcome` workflow, so a single request to `POST /v1/events` works right after `just dev`. `mix relay.dev.token` prints a token of the sample client. Running it again changes nothing.
  """

  @tenant "dev-sample-tenant"
  @recipient "dev-sample-recipient"
  @client "dev-sample-client"
  @workflow "welcome"
  @scopes ~w(publish read subscribers config kill_switch)
  @upserted ["created", "updated", "unchanged"]

  # T-65 (1)
  @doc "Seeds the sample data and returns the external identifiers it wrote."
  @spec run() :: {:ok, map()} | {:error, term()}
  def run do
    {:ok, actor} = Relay.Actor.new(:system, "system:dev_seed", "system:dev_seed")

    with {:ok, _report} <- Relay.Datasets.load_package(actor),
         {:ok, tenant_id} <- tenant(actor),
         test = Relay.Scope.new!(tenant_id, :test),
         {:ok, {result, _id}} when result in [:created, :exists] <-
           Relay.Tenancy.create_recipient(test, %{
             id: Relay.Id.generate(),
             kind: :subscriber,
             external_id: @recipient
           }),
         :ok <- RelayDev.Access.link(),
         {:ok, client_id} <- client(test),
         {:ok, version} <- workflow(test, actor) do
      {:ok,
       %{
         tenant: Relay.ExternalId.encode("ten", tenant_id),
         environments: [:live, :test],
         recipient: @recipient,
         api_client: Relay.ExternalId.encode("cli", client_id),
         workflow: @workflow,
         workflow_version: version
       }}
    end
  end

  @doc "A token of the sample test plane API client, valid for one hour; see `RelayDev.Access.server_token/4` for `audience`."
  @spec token(String.t() | nil) :: String.t()
  def token(audience \\ nil),
    do: RelayDev.Access.server_token(@tenant, @client, @scopes, audience)

  @doc "The body of a sample `POST /v1/events` request to the sample workflow."
  @spec sample_event() :: map()
  def sample_event do
    %{"workflow" => @workflow, "to" => [@recipient], "data" => %{"first_name" => "Ayşe"}}
  end

  @doc "The definition of the sample workflow: one inbox step."
  @spec definition() :: map()
  def definition do
    %{
      "name" => "Welcome",
      "category" => "account",
      "message_class" => "transactional",
      "event_schema" => %{
        "type" => "object",
        "properties" => %{"first_name" => %{"type" => "string"}},
        "required" => ["first_name"]
      },
      "steps" => [
        %{"type" => "channel", "key" => "inbox", "channel" => "in_app", "template" => "welcome"}
      ]
    }
  end

  defp tenant(actor) do
    {:ok, region} = Relay.Region.cast(RelayDev.Access.region())

    attrs = %{
      id: Relay.Id.generate(),
      access_tenant_id: @tenant,
      region: region,
      sector: "general",
      default_timezone: "Europe/Istanbul",
      default_locale: "tr-TR",
      record_digest: :crypto.hash(:sha256, "dev-seed:" <> @tenant)
    }

    case Relay.Tenancy.Provisioning.create_tenant(attrs, actor) do
      {result, id} when result in [:created, :exists] and is_binary(id) -> {:ok, id}
      other -> {:error, other}
    end
  end

  # API-44
  # API-75
  defp client(test) do
    {:ok, actor} = Relay.Actor.new(:access, "access", "access")
    digest = :crypto.hash(:sha256, "dev-seed:" <> @client)
    params = [Relay.Id.generate(), @client, nil, @scopes, "dev-seed", digest]
    upsert = fn _status ->
      Relay.Repo.call!("relay_fn.api_client_upsert", params ++ Relay.Actor.params(actor))
    end

    case Relay.Repo.in_scope(test, upsert) do
      {:ok, [%{"result" => result, "api_client_id" => id}]} when result in @upserted -> {:ok, id}
      other -> {:error, other}
    end
  end

  # WF-5
  # WF-6
  defp workflow(test, actor) do
    case Relay.Workflow.resolve_published(test, @workflow) do
      {:ok, {:ok, published}} -> {:ok, published["version_no"]}
      {:ok, :not_found} -> with :ok <- create(test, actor), do: publish(test, actor)
      {:ok, :not_published} -> publish(test, actor)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create(test, actor) do
    work = fn _status -> Relay.Workflow.create(test, @workflow, definition(), actor) end

    case Relay.Repo.in_scope(test, work) do
      {:ok, {:ok, {:created, _id, _version}}} -> :ok
      other -> {:error, other}
    end
  end

  defp publish(test, actor) do
    work = fn _status ->
      Relay.Workflow.request_publication(test, @workflow, nil, "dev seed", actor)
    end

    with {:ok, {:ok, {result, version_id}}} when result in [:pending, :already_pending] <-
           Relay.Repo.in_scope(test, work),
         {:ok, {:published, _errors}} <- Relay.Workflow.run_gate(test, version_id),
         {:ok, {:ok, published}} <- Relay.Workflow.resolve_published(test, @workflow) do
      {:ok, published["version_no"]}
    else
      other -> {:error, other}
    end
  end
end
