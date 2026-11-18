defmodule EsuissRelay.Api do
  @moduledoc """
  One function for every operation of the Relay server API, version 2026-11-01, generated
  from the OpenAPI contract by `mix esuiss_relay.gen`.

  Path parameters come first, then the request body when the operation requires one, then
  the options: query parameters and the request options of `EsuissRelay.Client`. Every
  function returns `{:ok, result}` or `{:error, error}` with an `EsuissRelay.Error`; a cursor
  list returns an `EsuissRelay.Page`.
  """

  alias EsuissRelay.Client
  alias EsuissRelay.Generated.Operations

  @doc "List agents.\n\n`GET /v1/agents`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_agents(Client.t(), keyword()) :: Client.result()
  def list_agents(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_agents), [], nil, opts)

  @doc "Create an agent.\n\n`POST /v1/agents`"
  @spec create_agent(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_agent(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_agent), [], body, opts)

  @doc "Get an agent.\n\n`GET /v1/agents/{agent_id}`"
  @spec get_agent(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_agent(client, agent_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_agent), [agent_id], nil, opts)

  @doc "Update an agent.\n\n`PATCH /v1/agents/{agent_id}`"
  @spec update_agent(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def update_agent(client, agent_id, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:update_agent), [agent_id], body, opts)

  @doc "Delete an agent.\n\n`DELETE /v1/agents/{agent_id}`"
  @spec delete_agent(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def delete_agent(client, agent_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:delete_agent), [agent_id], nil, opts)

  @doc "Decide on held agent notifications.\n\n`POST /v1/agents/{agent_id}/ceiling_decisions`"
  @spec create_agent_ceiling_decision(
          Client.t(),
          String.t() | integer(),
          map() | binary(),
          keyword()
        ) :: Client.result()
  def create_agent_ceiling_decision(client, agent_id, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:create_agent_ceiling_decision),
        [agent_id],
        body,
        opts
      )

  @doc "List held agent notifications.\n\n`GET /v1/agents/{agent_id}/ceiling_holds`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `state`."
  @spec list_agent_ceiling_holds(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def list_agent_ceiling_holds(client, agent_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_agent_ceiling_holds), [agent_id], nil, opts)

  @doc "Resume a stopped agent.\n\n`POST /v1/agents/{agent_id}/resume`"
  @spec resume_agent(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def resume_agent(client, agent_id, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:resume_agent), [agent_id], body, opts)

  @doc "Publish an AG-UI event.\n\n`POST /v1/agui/events`"
  @spec publish_ag_ui_event(Client.t(), map() | binary(), keyword()) :: Client.result()
  def publish_ag_ui_event(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:publish_ag_ui_event), [], body, opts)

  @doc "Get the brand settings.\n\n`GET /v1/brand`\n\nQuery: `subtenant`."
  @spec get_brand(Client.t(), keyword()) :: Client.result()
  def get_brand(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_brand), [], nil, opts)

  @doc "Update the brand settings.\n\n`PATCH /v1/brand`\n\nQuery: `subtenant`."
  @spec update_brand(Client.t(), map() | binary(), keyword()) :: Client.result()
  def update_brand(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:update_brand), [], body, opts)

  @doc "List campaigns.\n\n`GET /v1/campaigns`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_campaigns(Client.t(), keyword()) :: Client.result()
  def list_campaigns(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_campaigns), [], nil, opts)

  @doc "Create a campaign.\n\n`POST /v1/campaigns`"
  @spec create_campaign(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_campaign(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_campaign), [], body, opts)

  @doc "Get a campaign.\n\n`GET /v1/campaigns/{campaign_id}`"
  @spec get_campaign(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_campaign(client, campaign_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_campaign), [campaign_id], nil, opts)

  @doc "Approve the samples of a campaign.\n\n`POST /v1/campaigns/{campaign_id}/approve_samples`"
  @spec approve_campaign_samples(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def approve_campaign_samples(client, campaign_id, body, opts \\ []),
    do:
      Client.call(client, Operations.fetch!(:approve_campaign_samples), [campaign_id], body, opts)

  @doc "Cancel a campaign.\n\n`POST /v1/campaigns/{campaign_id}/cancel`"
  @spec cancel_campaign(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def cancel_campaign(client, campaign_id, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:cancel_campaign), [campaign_id], body, opts)

  @doc "Prepare a campaign.\n\n`POST /v1/campaigns/{campaign_id}/prepare`"
  @spec prepare_campaign(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def prepare_campaign(client, campaign_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:prepare_campaign), [campaign_id], nil, opts)

  @doc "Add recipients to a campaign.\n\n`POST /v1/campaigns/{campaign_id}/recipients`"
  @spec add_campaign_recipients(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def add_campaign_recipients(client, campaign_id, body, opts \\ []),
    do:
      Client.call(client, Operations.fetch!(:add_campaign_recipients), [campaign_id], body, opts)

  @doc "Render the samples of a campaign.\n\n`GET /v1/campaigns/{campaign_id}/samples`"
  @spec get_campaign_samples(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_campaign_samples(client, campaign_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_campaign_samples), [campaign_id], nil, opts)

  @doc "Trigger a campaign.\n\n`POST /v1/campaigns/{campaign_id}/trigger`"
  @spec trigger_campaign(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def trigger_campaign(client, campaign_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:trigger_campaign), [campaign_id], nil, opts)

  @doc "List categories.\n\n`GET /v1/categories`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_categories(Client.t(), keyword()) :: Client.result()
  def list_categories(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_categories), [], nil, opts)

  @doc "Create a category.\n\n`POST /v1/categories`"
  @spec create_category(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_category(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_category), [], body, opts)

  @doc "Get a category.\n\n`GET /v1/categories/{category_key}`"
  @spec get_category(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_category(client, category_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_category), [category_key], nil, opts)

  @doc "Update a category.\n\n`PATCH /v1/categories/{category_key}`"
  @spec update_category(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def update_category(client, category_key, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:update_category), [category_key], body, opts)

  @doc "Archive a category.\n\n`POST /v1/categories/{category_key}/archive`"
  @spec archive_category(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def archive_category(client, category_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:archive_category), [category_key], nil, opts)

  @doc "Get the e-mail tracking of a category.\n\n`GET /v1/categories/{category_key}/email_tracking`"
  @spec get_category_email_tracking(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def get_category_email_tracking(client, category_key, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_category_email_tracking),
        [category_key],
        nil,
        opts
      )

  @doc "Set the e-mail tracking of a category.\n\n`PUT /v1/categories/{category_key}/email_tracking`"
  @spec replace_category_email_tracking(
          Client.t(),
          String.t() | integer(),
          map() | binary(),
          keyword()
        ) :: Client.result()
  def replace_category_email_tracking(client, category_key, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:replace_category_email_tracking),
        [category_key],
        body,
        opts
      )

  @doc "Get a subtenant setting of a category.\n\n`GET /v1/categories/{category_key}/subtenants/{subtenant_id}`"
  @spec get_category_subtenant_setting(
          Client.t(),
          String.t() | integer(),
          String.t() | integer(),
          keyword()
        ) :: Client.result()
  def get_category_subtenant_setting(client, category_key, subtenant_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_category_subtenant_setting),
        [category_key, subtenant_id],
        nil,
        opts
      )

  @doc "Set a subtenant setting of a category.\n\n`PUT /v1/categories/{category_key}/subtenants/{subtenant_id}`"
  @spec replace_category_subtenant_setting(
          Client.t(),
          String.t() | integer(),
          String.t() | integer(),
          map() | binary(),
          keyword()
        ) :: Client.result()
  def replace_category_subtenant_setting(client, category_key, subtenant_id, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:replace_category_subtenant_setting),
        [category_key, subtenant_id],
        body,
        opts
      )

  @doc "List channel adapters.\n\n`GET /v1/channel_adapters`"
  @spec list_channel_adapters(Client.t(), keyword()) :: Client.result()
  def list_channel_adapters(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_channel_adapters), [], nil, opts)

  @doc "Quote the cost of a paid channel.\n\n`GET /v1/channel_costs`\n\nQuery: `channel`, `country`, `category`, `quantity`."
  @spec quote_channel_cost(Client.t(), keyword()) :: Client.result()
  def quote_channel_cost(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:quote_channel_cost), [], nil, opts)

  @doc "List channel identities.\n\n`GET /v1/channel_identities`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_channel_identities(Client.t(), keyword()) :: Client.result()
  def list_channel_identities(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_channel_identities), [], nil, opts)

  @doc "Get a channel identity.\n\n`GET /v1/channel_identities/{channel_identity_id}`"
  @spec get_channel_identity(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_channel_identity(client, channel_identity_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_channel_identity),
        [channel_identity_id],
        nil,
        opts
      )

  @doc "Update a channel identity.\n\n`PATCH /v1/channel_identities/{channel_identity_id}`"
  @spec update_channel_identity(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def update_channel_identity(client, channel_identity_id, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:update_channel_identity),
        [channel_identity_id],
        body,
        opts
      )

  @doc "Retire a channel identity.\n\n`POST /v1/channel_identities/{channel_identity_id}/archive`"
  @spec archive_channel_identity(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def archive_channel_identity(client, channel_identity_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:archive_channel_identity),
        [channel_identity_id],
        nil,
        opts
      )

  @doc "Get the compliance settings.\n\n`GET /v1/compliance_settings`"
  @spec get_compliance_settings(Client.t(), keyword()) :: Client.result()
  def get_compliance_settings(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_compliance_settings), [], nil, opts)

  @doc "Replace the tenant compliance settings.\n\n`PUT /v1/compliance_settings`"
  @spec replace_compliance_settings(Client.t(), map() | binary(), keyword()) :: Client.result()
  def replace_compliance_settings(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:replace_compliance_settings), [], body, opts)

  @doc "Get attempt history and ledger of a delivery.\n\n`GET /v1/deliveries/{delivery_id}/history`"
  @spec get_delivery_history(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_delivery_history(client, delivery_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_delivery_history), [delivery_id], nil, opts)

  @doc "Get the DLR windows.\n\n`GET /v1/delivery_windows`"
  @spec get_delivery_windows(Client.t(), keyword()) :: Client.result()
  def get_delivery_windows(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_delivery_windows), [], nil, opts)

  @doc "Replace the tenant DLR windows.\n\n`PUT /v1/delivery_windows`"
  @spec replace_delivery_windows(Client.t(), map() | binary(), keyword()) :: Client.result()
  def replace_delivery_windows(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:replace_delivery_windows), [], body, opts)

  @doc "Remove a device by its token.\n\n`DELETE /v1/devices/by-token`"
  @spec delete_device_by_token(Client.t(), map() | binary(), keyword()) :: Client.result()
  def delete_device_by_token(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:delete_device_by_token), [], body, opts)

  @doc "Upload a DMARC aggregate or TLS report.\n\n`POST /v1/email_reports`"
  @spec upload_email_report(Client.t(), map() | binary(), keyword()) :: Client.result()
  def upload_email_report(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:upload_email_report), [], body, opts)

  @doc "Summarize a domain's DMARC and TLS reports.\n\n`GET /v1/email_reports/summary`\n\nQuery: `domain`, `from`, `to`."
  @spec get_email_report_summary(Client.t(), keyword()) :: Client.result()
  def get_email_report_summary(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_email_report_summary), [], nil, opts)

  @doc "List the e-mail warm-up plans.\n\n`GET /v1/email_warmup_plans`"
  @spec list_email_warmup_plans(Client.t(), keyword()) :: Client.result()
  def list_email_warmup_plans(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_email_warmup_plans), [], nil, opts)

  @doc "List escalation policies.\n\n`GET /v1/escalation_policies`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `state`."
  @spec list_escalation_policies(Client.t(), keyword()) :: Client.result()
  def list_escalation_policies(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_escalation_policies), [], nil, opts)

  @doc "Get an escalation policy.\n\n`GET /v1/escalation_policies/{policy_key}`"
  @spec get_escalation_policy(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_escalation_policy(client, policy_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_escalation_policy), [policy_key], nil, opts)

  @doc "Write an escalation policy version.\n\n`PUT /v1/escalation_policies/{policy_key}`"
  @spec put_escalation_policy(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def put_escalation_policy(client, policy_key, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:put_escalation_policy), [policy_key], body, opts)

  @doc "Archive an escalation policy.\n\n`POST /v1/escalation_policies/{policy_key}/archive`"
  @spec archive_escalation_policy(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def archive_escalation_policy(client, policy_key, opts \\ []),
    do:
      Client.call(client, Operations.fetch!(:archive_escalation_policy), [policy_key], nil, opts)

  @doc "List escalation policy versions.\n\n`GET /v1/escalation_policies/{policy_key}/versions`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_escalation_policy_versions(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def list_escalation_policy_versions(client, policy_key, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:list_escalation_policy_versions),
        [policy_key],
        nil,
        opts
      )

  @doc "List CloudEvents type mappings.\n\n`GET /v1/event_type_mappings`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_event_type_mappings(Client.t(), keyword()) :: Client.result()
  def list_event_type_mappings(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_event_type_mappings), [], nil, opts)

  @doc "Create a CloudEvents type mapping.\n\n`POST /v1/event_type_mappings`"
  @spec create_event_type_mapping(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_event_type_mapping(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_event_type_mapping), [], body, opts)

  @doc "Get a CloudEvents type mapping.\n\n`GET /v1/event_type_mappings/{mapping_id}`"
  @spec get_event_type_mapping(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_event_type_mapping(client, mapping_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_event_type_mapping), [mapping_id], nil, opts)

  @doc "Replace a CloudEvents type mapping.\n\n`PUT /v1/event_type_mappings/{mapping_id}`"
  @spec replace_event_type_mapping(
          Client.t(),
          String.t() | integer(),
          map() | binary(),
          keyword()
        ) :: Client.result()
  def replace_event_type_mapping(client, mapping_id, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:replace_event_type_mapping),
        [mapping_id],
        body,
        opts
      )

  @doc "Archive a CloudEvents type mapping.\n\n`POST /v1/event_type_mappings/{mapping_id}/archive`"
  @spec archive_event_type_mapping(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def archive_event_type_mapping(client, mapping_id, opts \\ []),
    do:
      Client.call(client, Operations.fetch!(:archive_event_type_mapping), [mapping_id], nil, opts)

  @doc "Send an event.\n\n`POST /v1/events`"
  @spec create_event(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_event(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_event), [], body, opts)

  @doc "Send a batch of events.\n\n`POST /v1/events/batch`"
  @spec create_event_batch(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_event_batch(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_event_batch), [], body, opts)

  @doc "Cancel by cancellation key.\n\n`POST /v1/events/cancel_by_key`"
  @spec cancel_events_by_key(Client.t(), map() | binary(), keyword()) :: Client.result()
  def cancel_events_by_key(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:cancel_events_by_key), [], body, opts)

  @doc "Get an event.\n\n`GET /v1/events/{event_id}`"
  @spec get_event(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_event(client, event_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_event), [event_id], nil, opts)

  @doc "Cancel an event.\n\n`POST /v1/events/{event_id}/cancel`\n\nThe body is optional and passed as `:body`."
  @spec cancel_event(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def cancel_event(client, event_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:cancel_event), [event_id], nil, opts)

  @doc "List raw data exports.\n\n`GET /v1/exports`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_exports(Client.t(), keyword()) :: Client.result()
  def list_exports(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_exports), [], nil, opts)

  @doc "Request a raw data export.\n\n`POST /v1/exports`"
  @spec create_export(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_export(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_export), [], body, opts)

  @doc "Get a raw data export.\n\n`GET /v1/exports/{export_id}`"
  @spec get_export(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_export(client, export_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_export), [export_id], nil, opts)

  @doc "Publish an inbox announcement.\n\n`POST /v1/inbox/announcements`"
  @spec create_inbox_announcement(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_inbox_announcement(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_inbox_announcement), [], body, opts)

  @doc "Get an inbox announcement.\n\n`GET /v1/inbox/announcements/{announcement_id}`"
  @spec get_inbox_announcement(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_inbox_announcement(client, announcement_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_inbox_announcement),
        [announcement_id],
        nil,
        opts
      )

  @doc "Retract an inbox announcement.\n\n`POST /v1/inbox/announcements/{announcement_id}/retract`"
  @spec retract_inbox_announcement(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def retract_inbox_announcement(client, announcement_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:retract_inbox_announcement),
        [announcement_id],
        nil,
        opts
      )

  @doc "List the İYS brands.\n\n`GET /v1/iys/brands`"
  @spec list_iys_brands(Client.t(), keyword()) :: Client.result()
  def list_iys_brands(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_iys_brands), [], nil, opts)

  @doc "Get the İYS configuration.\n\n`GET /v1/iys/config`"
  @spec get_iys_config(Client.t(), keyword()) :: Client.result()
  def get_iys_config(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_iys_config), [], nil, opts)

  @doc "Replace the İYS configuration.\n\n`PUT /v1/iys/config`"
  @spec replace_iys_config(Client.t(), map() | binary(), keyword()) :: Client.result()
  def replace_iys_config(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:replace_iys_config), [], body, opts)

  @doc "Test the İYS connection.\n\n`GET /v1/iys/connection_test`"
  @spec test_iys_connection(Client.t(), keyword()) :: Client.result()
  def test_iys_connection(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:test_iys_connection), [], nil, opts)

  @doc "List İYS uploads.\n\n`GET /v1/iys/uploads`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `state`."
  @spec list_iys_uploads(Client.t(), keyword()) :: Client.result()
  def list_iys_uploads(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_iys_uploads), [], nil, opts)

  @doc "List kill switches.\n\n`GET /v1/kill_switches`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `include_released`."
  @spec list_kill_switches(Client.t(), keyword()) :: Client.result()
  def list_kill_switches(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_kill_switches), [], nil, opts)

  @doc "Engage a kill switch.\n\n`POST /v1/kill_switches`"
  @spec engage_kill_switch(Client.t(), map() | binary(), keyword()) :: Client.result()
  def engage_kill_switch(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:engage_kill_switch), [], body, opts)

  @doc "Get a kill switch.\n\n`GET /v1/kill_switches/{kill_switch_id}`"
  @spec get_kill_switch(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_kill_switch(client, kill_switch_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_kill_switch), [kill_switch_id], nil, opts)

  @doc "Replace the state of a kill switch.\n\n`POST /v1/kill_switches/{kill_switch_id}/replace`"
  @spec replace_kill_switch(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def replace_kill_switch(client, kill_switch_id, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:replace_kill_switch), [kill_switch_id], body, opts)

  @doc "List layouts.\n\n`GET /v1/layouts`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `subtenant`."
  @spec list_layouts(Client.t(), keyword()) :: Client.result()
  def list_layouts(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_layouts), [], nil, opts)

  @doc "Create a layout.\n\n`POST /v1/layouts`\n\nQuery: `subtenant`."
  @spec create_layout(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_layout(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_layout), [], body, opts)

  @doc "Get a layout.\n\n`GET /v1/layouts/{layout_key}`\n\nQuery: `subtenant`."
  @spec get_layout(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_layout(client, layout_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_layout), [layout_key], nil, opts)

  @doc "Replace the layout draft.\n\n`PUT /v1/layouts/{layout_key}`\n\nQuery: `subtenant`."
  @spec replace_layout_draft(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def replace_layout_draft(client, layout_key, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:replace_layout_draft), [layout_key], body, opts)

  @doc "Archive the layout.\n\n`POST /v1/layouts/{layout_key}/archive`\n\nQuery: `subtenant`."
  @spec archive_layout(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def archive_layout(client, layout_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:archive_layout), [layout_key], nil, opts)

  @doc "Publish the draft.\n\n`POST /v1/layouts/{layout_key}/publish`\n\nQuery: `subtenant`.\n\nThe body is optional and passed as `:body`."
  @spec publish_layout(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def publish_layout(client, layout_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:publish_layout), [layout_key], nil, opts)

  @doc "List layout versions.\n\n`GET /v1/layouts/{layout_key}/versions`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `subtenant`."
  @spec list_layout_versions(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def list_layout_versions(client, layout_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_layout_versions), [layout_key], nil, opts)

  @doc "Get a layout version.\n\n`GET /v1/layouts/{layout_key}/versions/{version}`\n\nQuery: `subtenant`."
  @spec get_layout_version(Client.t(), String.t() | integer(), String.t() | integer(), keyword()) ::
          Client.result()
  def get_layout_version(client, layout_key, version, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_layout_version),
        [layout_key, version],
        nil,
        opts
      )

  @doc "Roll back to a version.\n\n`POST /v1/layouts/{layout_key}/versions/{version}/promote`\n\nQuery: `subtenant`."
  @spec promote_layout_version(
          Client.t(),
          String.t() | integer(),
          String.t() | integer(),
          keyword()
        ) :: Client.result()
  def promote_layout_version(client, layout_key, version, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:promote_layout_version),
        [layout_key, version],
        nil,
        opts
      )

  @doc "Get the caller's mailbox.\n\n`GET /v1/mailbox`"
  @spec get_mailbox(Client.t(), keyword()) :: Client.result()
  def get_mailbox(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_mailbox), [], nil, opts)

  @doc "Report a mailbox message as abuse.\n\n`POST /v1/mailbox/abuse_reports`"
  @spec report_mailbox_abuse(Client.t(), map() | binary(), keyword()) :: Client.result()
  def report_mailbox_abuse(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:report_mailbox_abuse), [], body, opts)

  @doc "Acknowledge mailbox records.\n\n`POST /v1/mailbox/acks`"
  @spec ack_mailbox_records(Client.t(), map() | binary(), keyword()) :: Client.result()
  def ack_mailbox_records(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:ack_mailbox_records), [], body, opts)

  @doc "Block or unblock a sender.\n\n`POST /v1/mailbox/blocks`"
  @spec set_mailbox_sender_block(Client.t(), map() | binary(), keyword()) :: Client.result()
  def set_mailbox_sender_block(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:set_mailbox_sender_block), [], body, opts)

  @doc "List dead-lettered mailbox records.\n\n`GET /v1/mailbox/dead_letters`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `mailbox_id`."
  @spec list_mailbox_dead_letters(Client.t(), keyword()) :: Client.result()
  def list_mailbox_dead_letters(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_mailbox_dead_letters), [], nil, opts)

  @doc "Read the encrypted envelope of a message.\n\n`GET /v1/mailbox/envelopes`\n\nQuery: `record_id`."
  @spec get_mailbox_envelope(Client.t(), keyword()) :: Client.result()
  def get_mailbox_envelope(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_mailbox_envelope), [], nil, opts)

  @doc "Lease mailbox records.\n\n`POST /v1/mailbox/leases`\n\nThe body is optional and passed as `:body`."
  @spec lease_mailbox_records(Client.t(), keyword()) :: Client.result()
  def lease_mailbox_records(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:lease_mailbox_records), [], nil, opts)

  @doc "Send a message to an agent's mailbox.\n\n`POST /v1/mailbox/messages`"
  @spec send_mailbox_message(Client.t(), map() | binary(), keyword()) :: Client.result()
  def send_mailbox_message(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:send_mailbox_message), [], body, opts)

  @doc "Read mailbox records in order.\n\n`GET /v1/mailbox/records`\n\nQuery: `since`, `limit`."
  @spec list_mailbox_records(Client.t(), keyword()) :: Client.result()
  def list_mailbox_records(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_mailbox_records), [], nil, opts)

  @doc "Get a mailbox record by its handle.\n\n`GET /v1/mailbox/records/{record_id}`\n\nQuery: `content`."
  @spec get_mailbox_record(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_mailbox_record(client, record_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_mailbox_record), [record_id], nil, opts)

  @doc "List the request box.\n\n`GET /v1/mailbox/requests`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_mailbox_requests(Client.t(), keyword()) :: Client.result()
  def list_mailbox_requests(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_mailbox_requests), [], nil, opts)

  @doc "Call the MCP server.\n\n`POST /v1/mcp`"
  @spec call_mcp(Client.t(), map() | binary(), keyword()) :: Client.result()
  def call_mcp(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:call_mcp), [], body, opts)

  @doc "Install a messaging channel identity in a workspace.\n\n`POST /v1/messaging_installations`"
  @spec create_messaging_installation(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_messaging_installation(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_messaging_installation), [], body, opts)

  @doc "List notifications.\n\n`GET /v1/notifications`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `subscriber`, `workflow`, `status`, `created_after`, `created_before`, `is_test`."
  @spec list_notifications(Client.t(), keyword()) :: Client.result()
  def list_notifications(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_notifications), [], nil, opts)

  @doc "Get a notification.\n\n`GET /v1/notifications/{notification_id}`\n\nQuery: `expand`."
  @spec get_notification(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_notification(client, notification_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_notification), [notification_id], nil, opts)

  @doc "Cancel a notification.\n\n`POST /v1/notifications/{notification_id}/cancel`\n\nThe body is optional and passed as `:body`."
  @spec cancel_notification(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def cancel_notification(client, notification_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:cancel_notification), [notification_id], nil, opts)

  @doc "List deliveries of a notification.\n\n`GET /v1/notifications/{notification_id}/deliveries`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_notification_deliveries(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def list_notification_deliveries(client, notification_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:list_notification_deliveries),
        [notification_id],
        nil,
        opts
      )

  @doc "Get the operations contacts.\n\n`GET /v1/operations_contacts`"
  @spec get_operations_contacts(Client.t(), keyword()) :: Client.result()
  def get_operations_contacts(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_operations_contacts), [], nil, opts)

  @doc "Replace the operations contacts.\n\n`PUT /v1/operations_contacts`"
  @spec replace_operations_contacts(Client.t(), map() | binary(), keyword()) :: Client.result()
  def replace_operations_contacts(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:replace_operations_contacts), [], body, opts)

  @doc "List partials.\n\n`GET /v1/partials`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `subtenant`."
  @spec list_partials(Client.t(), keyword()) :: Client.result()
  def list_partials(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_partials), [], nil, opts)

  @doc "Create a partial.\n\n`POST /v1/partials`\n\nQuery: `subtenant`."
  @spec create_partial(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_partial(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_partial), [], body, opts)

  @doc "Get a partial.\n\n`GET /v1/partials/{partial_key}`\n\nQuery: `subtenant`."
  @spec get_partial(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_partial(client, partial_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_partial), [partial_key], nil, opts)

  @doc "Replace the partial draft.\n\n`PUT /v1/partials/{partial_key}`\n\nQuery: `subtenant`."
  @spec replace_partial_draft(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def replace_partial_draft(client, partial_key, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:replace_partial_draft), [partial_key], body, opts)

  @doc "Archive the partial.\n\n`POST /v1/partials/{partial_key}/archive`\n\nQuery: `subtenant`."
  @spec archive_partial(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def archive_partial(client, partial_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:archive_partial), [partial_key], nil, opts)

  @doc "Publish the draft.\n\n`POST /v1/partials/{partial_key}/publish`\n\nQuery: `subtenant`.\n\nThe body is optional and passed as `:body`."
  @spec publish_partial(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def publish_partial(client, partial_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:publish_partial), [partial_key], nil, opts)

  @doc "List partial versions.\n\n`GET /v1/partials/{partial_key}/versions`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `subtenant`."
  @spec list_partial_versions(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def list_partial_versions(client, partial_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_partial_versions), [partial_key], nil, opts)

  @doc "Get a partial version.\n\n`GET /v1/partials/{partial_key}/versions/{version}`\n\nQuery: `subtenant`."
  @spec get_partial_version(Client.t(), String.t() | integer(), String.t() | integer(), keyword()) ::
          Client.result()
  def get_partial_version(client, partial_key, version, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_partial_version),
        [partial_key, version],
        nil,
        opts
      )

  @doc "Roll back to a version.\n\n`POST /v1/partials/{partial_key}/versions/{version}/promote`\n\nQuery: `subtenant`."
  @spec promote_partial_version(
          Client.t(),
          String.t() | integer(),
          String.t() | integer(),
          keyword()
        ) :: Client.result()
  def promote_partial_version(client, partial_key, version, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:promote_partial_version),
        [partial_key, version],
        nil,
        opts
      )

  @doc "Publish a producer template.\n\n`PUT /v1/producer_templates/{template_key}`"
  @spec publish_producer_template(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def publish_producer_template(client, template_key, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:publish_producer_template),
        [template_key],
        body,
        opts
      )

  @doc "List provider accounts.\n\n`GET /v1/provider_accounts`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_provider_accounts(Client.t(), keyword()) :: Client.result()
  def list_provider_accounts(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_provider_accounts), [], nil, opts)

  @doc "Get a provider account.\n\n`GET /v1/provider_accounts/{provider_account_id}`"
  @spec get_provider_account(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_provider_account(client, provider_account_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_provider_account),
        [provider_account_id],
        nil,
        opts
      )

  @doc "Update a provider account.\n\n`PATCH /v1/provider_accounts/{provider_account_id}`"
  @spec update_provider_account(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def update_provider_account(client, provider_account_id, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:update_provider_account),
        [provider_account_id],
        body,
        opts
      )

  @doc "Check the sending domains of an e-mail provider account.\n\n`GET /v1/provider_accounts/{provider_account_id}/email_domains`"
  @spec get_provider_account_email_domains(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def get_provider_account_email_domains(client, provider_account_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_provider_account_email_domains),
        [provider_account_id],
        nil,
        opts
      )

  @doc "Get the status of a provider account.\n\n`GET /v1/provider_accounts/{provider_account_id}/status`"
  @spec get_provider_account_status(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def get_provider_account_status(client, provider_account_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_provider_account_status),
        [provider_account_id],
        nil,
        opts
      )

  @doc "Verify a provider account.\n\n`POST /v1/provider_accounts/{provider_account_id}/verify`"
  @spec verify_provider_account(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def verify_provider_account(client, provider_account_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:verify_provider_account),
        [provider_account_id],
        nil,
        opts
      )

  @doc "List provider invoices.\n\n`GET /v1/provider_invoices`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_provider_invoices(Client.t(), keyword()) :: Client.result()
  def list_provider_invoices(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_provider_invoices), [], nil, opts)

  @doc "Record a provider invoice.\n\n`POST /v1/provider_invoices`"
  @spec create_provider_invoice(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_provider_invoice(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_provider_invoice), [], body, opts)

  @doc "Get a provider invoice.\n\n`GET /v1/provider_invoices/{provider_invoice_id}`"
  @spec get_provider_invoice(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_provider_invoice(client, provider_invoice_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_provider_invoice),
        [provider_invoice_id],
        nil,
        opts
      )

  @doc "Get the allowed browser origins.\n\n`GET /v1/realtime_origins`"
  @spec get_realtime_origins(Client.t(), keyword()) :: Client.result()
  def get_realtime_origins(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_realtime_origins), [], nil, opts)

  @doc "Set the allowed browser origins.\n\n`PUT /v1/realtime_origins`"
  @spec set_realtime_origins(Client.t(), map() | binary(), keyword()) :: Client.result()
  def set_realtime_origins(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:set_realtime_origins), [], body, opts)

  @doc "List recurrence rules.\n\n`GET /v1/recurrences`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_recurrences(Client.t(), keyword()) :: Client.result()
  def list_recurrences(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_recurrences), [], nil, opts)

  @doc "Define a recurrence rule.\n\n`POST /v1/recurrences`"
  @spec create_recurrence(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_recurrence(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_recurrence), [], body, opts)

  @doc "Get a recurrence rule.\n\n`GET /v1/recurrences/{recurrence_id}`"
  @spec get_recurrence(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_recurrence(client, recurrence_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_recurrence), [recurrence_id], nil, opts)

  @doc "Cancel a recurrence rule.\n\n`POST /v1/recurrences/{recurrence_id}/cancel`"
  @spec cancel_recurrence(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def cancel_recurrence(client, recurrence_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:cancel_recurrence), [recurrence_id], nil, opts)

  @doc "Get the cost report.\n\n`GET /v1/reports/costs`\n\nQuery: `from`, `to`."
  @spec get_cost_report(Client.t(), keyword()) :: Client.result()
  def get_cost_report(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_cost_report), [], nil, opts)

  @doc "Get the delivery report.\n\n`GET /v1/reports/deliveries`\n\nQuery: `from`, `to`."
  @spec get_delivery_report(Client.t(), keyword()) :: Client.result()
  def get_delivery_report(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_delivery_report), [], nil, opts)

  @doc "Get the skip distribution.\n\n`GET /v1/reports/skips`\n\nQuery: `from`, `to`."
  @spec get_skip_report(Client.t(), keyword()) :: Client.result()
  def get_skip_report(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_skip_report), [], nil, opts)

  @doc "List routes.\n\n`GET /v1/routes`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_routes(Client.t(), keyword()) :: Client.result()
  def list_routes(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_routes), [], nil, opts)

  @doc "Create a route.\n\n`POST /v1/routes`"
  @spec create_route(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_route(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_route), [], body, opts)

  @doc "Get a route.\n\n`GET /v1/routes/{route_key}`"
  @spec get_route(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_route(client, route_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_route), [route_key], nil, opts)

  @doc "Replace a route.\n\n`PUT /v1/routes/{route_key}`"
  @spec replace_route(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def replace_route(client, route_key, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:replace_route), [route_key], body, opts)

  @doc "Archive a route.\n\n`POST /v1/routes/{route_key}/archive`"
  @spec archive_route(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def archive_route(client, route_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:archive_route), [route_key], nil, opts)

  @doc "List sender identities.\n\n`GET /v1/sender_identities`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_sender_identities(Client.t(), keyword()) :: Client.result()
  def list_sender_identities(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_sender_identities), [], nil, opts)

  @doc "Create a sender identity.\n\n`POST /v1/sender_identities`"
  @spec create_sender_identity(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_sender_identity(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_sender_identity), [], body, opts)

  @doc "Get a sender identity.\n\n`GET /v1/sender_identities/{sender_identity_id}`"
  @spec get_sender_identity(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_sender_identity(client, sender_identity_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_sender_identity),
        [sender_identity_id],
        nil,
        opts
      )

  @doc "Update a sender identity.\n\n`PATCH /v1/sender_identities/{sender_identity_id}`"
  @spec update_sender_identity(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def update_sender_identity(client, sender_identity_id, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:update_sender_identity),
        [sender_identity_id],
        body,
        opts
      )

  @doc "Archive a sender identity.\n\n`POST /v1/sender_identities/{sender_identity_id}/archive`"
  @spec archive_sender_identity(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def archive_sender_identity(client, sender_identity_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:archive_sender_identity),
        [sender_identity_id],
        nil,
        opts
      )

  @doc "Get the SMS destination policy.\n\n`GET /v1/sms_destination_policy`"
  @spec get_sms_destination_policy(Client.t(), keyword()) :: Client.result()
  def get_sms_destination_policy(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_sms_destination_policy), [], nil, opts)

  @doc "Set the SMS destination policy.\n\n`PUT /v1/sms_destination_policy`"
  @spec set_sms_destination_policy(Client.t(), map() | binary(), keyword()) :: Client.result()
  def set_sms_destination_policy(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:set_sms_destination_policy), [], body, opts)

  @doc "List SMS destination stops.\n\n`GET /v1/sms_destination_stops`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `state`."
  @spec list_sms_destination_stops(Client.t(), keyword()) :: Client.result()
  def list_sms_destination_stops(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_sms_destination_stops), [], nil, opts)

  @doc "Lift an SMS destination stop.\n\n`POST /v1/sms_destination_stops/{sms_destination_stop_id}/lift`"
  @spec lift_sms_destination_stop(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def lift_sms_destination_stop(client, sms_destination_stop_id, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:lift_sms_destination_stop),
        [sms_destination_stop_id],
        body,
        opts
      )

  @doc "List subscribers.\n\n`GET /v1/subscribers`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_subscribers(Client.t(), keyword()) :: Client.result()
  def list_subscribers(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_subscribers), [], nil, opts)

  @doc "Create a subscriber.\n\n`POST /v1/subscribers`"
  @spec create_subscriber(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_subscriber(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_subscriber), [], body, opts)

  @doc "Bulk upsert subscribers.\n\n`POST /v1/subscribers/bulk`"
  @spec bulk_upsert_subscribers(Client.t(), map() | binary(), keyword()) :: Client.result()
  def bulk_upsert_subscribers(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:bulk_upsert_subscribers), [], body, opts)

  @doc "Get a subscriber.\n\n`GET /v1/subscribers/{subscriber_id}`"
  @spec get_subscriber(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_subscriber(client, subscriber_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_subscriber), [subscriber_id], nil, opts)

  @doc "Create or replace a subscriber.\n\n`PUT /v1/subscribers/{subscriber_id}`"
  @spec replace_subscriber(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def replace_subscriber(client, subscriber_id, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:replace_subscriber), [subscriber_id], body, opts)

  @doc "Update a subscriber.\n\n`PATCH /v1/subscribers/{subscriber_id}`"
  @spec update_subscriber(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def update_subscriber(client, subscriber_id, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:update_subscriber), [subscriber_id], body, opts)

  @doc "Request deletion of a subscriber.\n\n`DELETE /v1/subscribers/{subscriber_id}`"
  @spec delete_subscriber(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def delete_subscriber(client, subscriber_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:delete_subscriber), [subscriber_id], nil, opts)

  @doc "List subscriber consents.\n\n`GET /v1/subscribers/{subscriber_id}/consents`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_subscriber_consents(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def list_subscriber_consents(client, subscriber_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:list_subscriber_consents),
        [subscriber_id],
        nil,
        opts
      )

  @doc "Explain why a subscriber did or did not get notifications.\n\n`GET /v1/subscribers/{subscriber_id}/decisions`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `created_after`, `created_before`, `workflow`."
  @spec list_subscriber_decisions(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def list_subscriber_decisions(client, subscriber_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:list_subscriber_decisions),
        [subscriber_id],
        nil,
        opts
      )

  @doc "List subscriber devices.\n\n`GET /v1/subscribers/{subscriber_id}/devices`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_subscriber_devices(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def list_subscriber_devices(client, subscriber_id, opts \\ []),
    do:
      Client.call(client, Operations.fetch!(:list_subscriber_devices), [subscriber_id], nil, opts)

  @doc "Register a subscriber device.\n\n`POST /v1/subscribers/{subscriber_id}/devices`"
  @spec register_subscriber_device(
          Client.t(),
          String.t() | integer(),
          map() | binary(),
          keyword()
        ) :: Client.result()
  def register_subscriber_device(client, subscriber_id, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:register_subscriber_device),
        [subscriber_id],
        body,
        opts
      )

  @doc "Remove a subscriber device.\n\n`DELETE /v1/subscribers/{subscriber_id}/devices/{device_id}`"
  @spec delete_subscriber_device(
          Client.t(),
          String.t() | integer(),
          String.t() | integer(),
          keyword()
        ) :: Client.result()
  def delete_subscriber_device(client, subscriber_id, device_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:delete_subscriber_device),
        [subscriber_id, device_id],
        nil,
        opts
      )

  @doc "Put a subscriber's messaging conversation.\n\n`PUT /v1/subscribers/{subscriber_id}/messaging_targets/{channel}`"
  @spec replace_subscriber_messaging_target(
          Client.t(),
          String.t() | integer(),
          String.t() | integer(),
          map() | binary(),
          keyword()
        ) :: Client.result()
  def replace_subscriber_messaging_target(client, subscriber_id, channel, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:replace_subscriber_messaging_target),
        [subscriber_id, channel],
        body,
        opts
      )

  @doc "Remove a subscriber's messaging conversation.\n\n`DELETE /v1/subscribers/{subscriber_id}/messaging_targets/{channel}`"
  @spec delete_subscriber_messaging_target(
          Client.t(),
          String.t() | integer(),
          String.t() | integer(),
          keyword()
        ) :: Client.result()
  def delete_subscriber_messaging_target(client, subscriber_id, channel, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:delete_subscriber_messaging_target),
        [subscriber_id, channel],
        nil,
        opts
      )

  @doc "Mint a hosted preference page link.\n\n`POST /v1/subscribers/{subscriber_id}/preference_page_links`"
  @spec create_preference_page_link(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def create_preference_page_link(client, subscriber_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:create_preference_page_link),
        [subscriber_id],
        nil,
        opts
      )

  @doc "Get subscriber preferences.\n\n`GET /v1/subscribers/{subscriber_id}/preferences`"
  @spec get_subscriber_preferences(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def get_subscriber_preferences(client, subscriber_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_subscriber_preferences),
        [subscriber_id],
        nil,
        opts
      )

  @doc "Update subscriber preferences.\n\n`PATCH /v1/subscribers/{subscriber_id}/preferences`"
  @spec update_subscriber_preferences(
          Client.t(),
          String.t() | integer(),
          map() | binary(),
          keyword()
        ) :: Client.result()
  def update_subscriber_preferences(client, subscriber_id, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:update_subscriber_preferences),
        [subscriber_id],
        body,
        opts
      )

  @doc "List the topics a subscriber is subscribed to.\n\n`GET /v1/subscribers/{subscriber_id}/subscriptions`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_subscriber_subscriptions(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def list_subscriber_subscriptions(client, subscriber_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:list_subscriber_subscriptions),
        [subscriber_id],
        nil,
        opts
      )

  @doc "List suppressions.\n\n`GET /v1/suppressions`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `channel`, `reason`, `state`."
  @spec list_suppressions(Client.t(), keyword()) :: Client.result()
  def list_suppressions(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_suppressions), [], nil, opts)

  @doc "Add a suppression.\n\n`POST /v1/suppressions`"
  @spec create_suppression(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_suppression(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_suppression), [], body, opts)

  @doc "Lift a suppression.\n\n`POST /v1/suppressions/{suppression_id}/lift`"
  @spec lift_suppression(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def lift_suppression(client, suppression_id, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:lift_suppression), [suppression_id], body, opts)

  @doc "List templates.\n\n`GET /v1/templates`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `subtenant`."
  @spec list_templates(Client.t(), keyword()) :: Client.result()
  def list_templates(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_templates), [], nil, opts)

  @doc "Create a template.\n\n`POST /v1/templates`\n\nQuery: `subtenant`."
  @spec create_template(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_template(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_template), [], body, opts)

  @doc "Get a template.\n\n`GET /v1/templates/{template_key}`\n\nQuery: `subtenant`."
  @spec get_template(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_template(client, template_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_template), [template_key], nil, opts)

  @doc "Replace the template draft.\n\n`PUT /v1/templates/{template_key}`\n\nQuery: `subtenant`."
  @spec replace_template_draft(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def replace_template_draft(client, template_key, body, opts \\ []),
    do:
      Client.call(client, Operations.fetch!(:replace_template_draft), [template_key], body, opts)

  @doc "Archive the template.\n\n`POST /v1/templates/{template_key}/archive`\n\nQuery: `subtenant`."
  @spec archive_template(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def archive_template(client, template_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:archive_template), [template_key], nil, opts)

  @doc "Get the e-mail tracking of a template.\n\n`GET /v1/templates/{template_key}/email_tracking`"
  @spec get_template_email_tracking(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def get_template_email_tracking(client, template_key, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_template_email_tracking),
        [template_key],
        nil,
        opts
      )

  @doc "Set the e-mail tracking of a template.\n\n`PUT /v1/templates/{template_key}/email_tracking`"
  @spec replace_template_email_tracking(
          Client.t(),
          String.t() | integer(),
          map() | binary(),
          keyword()
        ) :: Client.result()
  def replace_template_email_tracking(client, template_key, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:replace_template_email_tracking),
        [template_key],
        body,
        opts
      )

  @doc "Preview a template.\n\n`POST /v1/templates/{template_key}/preview`\n\nQuery: `subtenant`."
  @spec preview_template(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def preview_template(client, template_key, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:preview_template), [template_key], body, opts)

  @doc "Publish the draft.\n\n`POST /v1/templates/{template_key}/publish`\n\nQuery: `subtenant`.\n\nThe body is optional and passed as `:body`."
  @spec publish_template(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def publish_template(client, template_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:publish_template), [template_key], nil, opts)

  @doc "Get the translation matrix.\n\n`GET /v1/templates/{template_key}/translations`\n\nQuery: `source`, `subtenant`."
  @spec get_template_translations(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def get_template_translations(client, template_key, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_template_translations),
        [template_key],
        nil,
        opts
      )

  @doc "List template versions.\n\n`GET /v1/templates/{template_key}/versions`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `subtenant`."
  @spec list_template_versions(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def list_template_versions(client, template_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_template_versions), [template_key], nil, opts)

  @doc "Get a template version.\n\n`GET /v1/templates/{template_key}/versions/{version}`\n\nQuery: `subtenant`."
  @spec get_template_version(
          Client.t(),
          String.t() | integer(),
          String.t() | integer(),
          keyword()
        ) :: Client.result()
  def get_template_version(client, template_key, version, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_template_version),
        [template_key, version],
        nil,
        opts
      )

  @doc "Roll back to a version.\n\n`POST /v1/templates/{template_key}/versions/{version}/promote`\n\nQuery: `subtenant`."
  @spec promote_template_version(
          Client.t(),
          String.t() | integer(),
          String.t() | integer(),
          keyword()
        ) :: Client.result()
  def promote_template_version(client, template_key, version, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:promote_template_version),
        [template_key, version],
        nil,
        opts
      )

  @doc "List the simulated results of the fake provider.\n\n`GET /v1/test/simulated-results`"
  @spec list_simulated_results(Client.t(), keyword()) :: Client.result()
  def list_simulated_results(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_simulated_results), [], nil, opts)

  @doc "List test recipients.\n\n`GET /v1/test_recipients`"
  @spec list_test_recipients(Client.t(), keyword()) :: Client.result()
  def list_test_recipients(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_test_recipients), [], nil, opts)

  @doc "Add a test recipient.\n\n`POST /v1/test_recipients`"
  @spec create_test_recipient(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_test_recipient(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_test_recipient), [], body, opts)

  @doc "Remove a test recipient.\n\n`POST /v1/test_recipients/{test_recipient_id}/remove`"
  @spec remove_test_recipient(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def remove_test_recipient(client, test_recipient_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:remove_test_recipient),
        [test_recipient_id],
        nil,
        opts
      )

  @doc "Reset an active throttle.\n\n`POST /v1/throttles/{throttle_key}/reset`"
  @spec reset_throttle(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def reset_throttle(client, throttle_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:reset_throttle), [throttle_key], nil, opts)

  @doc "Get the jitter control.\n\n`GET /v1/timing_settings`"
  @spec get_timing_settings(Client.t(), keyword()) :: Client.result()
  def get_timing_settings(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_timing_settings), [], nil, opts)

  @doc "Set the jitter control.\n\n`PUT /v1/timing_settings`"
  @spec set_timing_settings(Client.t(), map() | binary(), keyword()) :: Client.result()
  def set_timing_settings(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:set_timing_settings), [], body, opts)

  @doc "List topics.\n\n`GET /v1/topics`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_topics(Client.t(), keyword()) :: Client.result()
  def list_topics(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_topics), [], nil, opts)

  @doc "Create a topic.\n\n`POST /v1/topics`"
  @spec create_topic(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_topic(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_topic), [], body, opts)

  @doc "Get a topic.\n\n`GET /v1/topics/{topic_key}`"
  @spec get_topic(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_topic(client, topic_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_topic), [topic_key], nil, opts)

  @doc "Archive a topic.\n\n`POST /v1/topics/{topic_key}/archive`"
  @spec archive_topic(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def archive_topic(client, topic_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:archive_topic), [topic_key], nil, opts)

  @doc "List the subscriptions of a topic.\n\n`GET /v1/topics/{topic_key}/subscriptions`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_topic_subscriptions(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def list_topic_subscriptions(client, topic_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_topic_subscriptions), [topic_key], nil, opts)

  @doc "Subscribe subscribers to a topic.\n\n`POST /v1/topics/{topic_key}/subscriptions`"
  @spec add_topic_subscriptions(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def add_topic_subscriptions(client, topic_key, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:add_topic_subscriptions), [topic_key], body, opts)

  @doc "Unsubscribe subscribers from a topic.\n\n`POST /v1/topics/{topic_key}/subscriptions/remove`"
  @spec remove_topic_subscriptions(
          Client.t(),
          String.t() | integer(),
          map() | binary(),
          keyword()
        ) :: Client.result()
  def remove_topic_subscriptions(client, topic_key, body, opts \\ []),
    do:
      Client.call(client, Operations.fetch!(:remove_topic_subscriptions), [topic_key], body, opts)

  @doc "Get the virtual clock.\n\n`GET /v1/virtual_clock`"
  @spec get_virtual_clock(Client.t(), keyword()) :: Client.result()
  def get_virtual_clock(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_virtual_clock), [], nil, opts)

  @doc "Advance the virtual clock.\n\n`POST /v1/virtual_clock/advance`"
  @spec advance_virtual_clock(Client.t(), map() | binary(), keyword()) :: Client.result()
  def advance_virtual_clock(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:advance_virtual_clock), [], body, opts)

  @doc "List waitpoints.\n\n`GET /v1/waitpoints`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `state`, `awaiting_response`, `waiter`, `tag`."
  @spec list_waitpoints(Client.t(), keyword()) :: Client.result()
  def list_waitpoints(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_waitpoints), [], nil, opts)

  @doc "Create a waitpoint.\n\n`POST /v1/waitpoints`"
  @spec create_waitpoint(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_waitpoint(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_waitpoint), [], body, opts)

  @doc "Get a waitpoint.\n\n`GET /v1/waitpoints/{waitpoint_id}`"
  @spec get_waitpoint(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_waitpoint(client, waitpoint_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_waitpoint), [waitpoint_id], nil, opts)

  @doc "Cancel a waitpoint.\n\n`POST /v1/waitpoints/{waitpoint_id}/cancel`"
  @spec cancel_waitpoint(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def cancel_waitpoint(client, waitpoint_id, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:cancel_waitpoint), [waitpoint_id], body, opts)

  @doc "Send a waiter heartbeat.\n\n`POST /v1/waitpoints/{waitpoint_id}/heartbeat`"
  @spec heartbeat_waitpoint(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def heartbeat_waitpoint(client, waitpoint_id, opts \\ []),
    do: Client.call(client, Operations.fetch!(:heartbeat_waitpoint), [waitpoint_id], nil, opts)

  @doc "List Relay's event catalog.\n\n`GET /v1/webhook_catalog`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_webhook_catalog(Client.t(), keyword()) :: Client.result()
  def list_webhook_catalog(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_webhook_catalog), [], nil, opts)

  @doc "List webhook consumers.\n\n`GET /v1/webhook_consumers`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `state`."
  @spec list_webhook_consumers(Client.t(), keyword()) :: Client.result()
  def list_webhook_consumers(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_webhook_consumers), [], nil, opts)

  @doc "Create a webhook consumer.\n\n`POST /v1/webhook_consumers`"
  @spec create_webhook_consumer(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_webhook_consumer(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_webhook_consumer), [], body, opts)

  @doc "Get a webhook consumer.\n\n`GET /v1/webhook_consumers/{webhook_consumer_id}`"
  @spec get_webhook_consumer(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_webhook_consumer(client, webhook_consumer_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_webhook_consumer),
        [webhook_consumer_id],
        nil,
        opts
      )

  @doc "Update a webhook consumer.\n\n`PATCH /v1/webhook_consumers/{webhook_consumer_id}`"
  @spec update_webhook_consumer(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def update_webhook_consumer(client, webhook_consumer_id, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:update_webhook_consumer),
        [webhook_consumer_id],
        body,
        opts
      )

  @doc "Archive a webhook consumer.\n\n`POST /v1/webhook_consumers/{webhook_consumer_id}/archive`"
  @spec archive_webhook_consumer(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def archive_webhook_consumer(client, webhook_consumer_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:archive_webhook_consumer),
        [webhook_consumer_id],
        nil,
        opts
      )

  @doc "Mint a webhook portal token.\n\n`POST /v1/webhook_consumers/{webhook_consumer_id}/portal_tokens`"
  @spec create_webhook_portal_token(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def create_webhook_portal_token(client, webhook_consumer_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:create_webhook_portal_token),
        [webhook_consumer_id],
        nil,
        opts
      )

  @doc "List webhook endpoints.\n\n`GET /v1/webhook_endpoints`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `use`, `state`, `consumer_id`."
  @spec list_webhook_endpoints(Client.t(), keyword()) :: Client.result()
  def list_webhook_endpoints(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_webhook_endpoints), [], nil, opts)

  @doc "Create a webhook endpoint.\n\n`POST /v1/webhook_endpoints`"
  @spec create_webhook_endpoint(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_webhook_endpoint(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_webhook_endpoint), [], body, opts)

  @doc "Get a webhook endpoint.\n\n`GET /v1/webhook_endpoints/{webhook_endpoint_id}`"
  @spec get_webhook_endpoint(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_webhook_endpoint(client, webhook_endpoint_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_webhook_endpoint),
        [webhook_endpoint_id],
        nil,
        opts
      )

  @doc "Update a webhook endpoint.\n\n`PATCH /v1/webhook_endpoints/{webhook_endpoint_id}`"
  @spec update_webhook_endpoint(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def update_webhook_endpoint(client, webhook_endpoint_id, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:update_webhook_endpoint),
        [webhook_endpoint_id],
        body,
        opts
      )

  @doc "Archive a webhook endpoint.\n\n`POST /v1/webhook_endpoints/{webhook_endpoint_id}/archive`"
  @spec archive_webhook_endpoint(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def archive_webhook_endpoint(client, webhook_endpoint_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:archive_webhook_endpoint),
        [webhook_endpoint_id],
        nil,
        opts
      )

  @doc "Cancel scheduled retries.\n\n`POST /v1/webhook_endpoints/{webhook_endpoint_id}/cancel_retries`\n\nThe body is optional and passed as `:body`."
  @spec cancel_webhook_endpoint_retries(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def cancel_webhook_endpoint_retries(client, webhook_endpoint_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:cancel_webhook_endpoint_retries),
        [webhook_endpoint_id],
        nil,
        opts
      )

  @doc "Get the health of an endpoint.\n\n`GET /v1/webhook_endpoints/{webhook_endpoint_id}/health`"
  @spec get_webhook_endpoint_health(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def get_webhook_endpoint_health(client, webhook_endpoint_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_webhook_endpoint_health),
        [webhook_endpoint_id],
        nil,
        opts
      )

  @doc "List missed events.\n\n`GET /v1/webhook_endpoints/{webhook_endpoint_id}/missed_events`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `event_type`, `created_after`, `created_before`."
  @spec list_webhook_endpoint_missed_events(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def list_webhook_endpoint_missed_events(client, webhook_endpoint_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:list_webhook_endpoint_missed_events),
        [webhook_endpoint_id],
        nil,
        opts
      )

  @doc "Pause a webhook endpoint.\n\n`POST /v1/webhook_endpoints/{webhook_endpoint_id}/pause`"
  @spec pause_webhook_endpoint(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def pause_webhook_endpoint(client, webhook_endpoint_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:pause_webhook_endpoint),
        [webhook_endpoint_id],
        nil,
        opts
      )

  @doc "Recover an endpoint.\n\n`POST /v1/webhook_endpoints/{webhook_endpoint_id}/recover`"
  @spec recover_webhook_endpoint(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def recover_webhook_endpoint(client, webhook_endpoint_id, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:recover_webhook_endpoint),
        [webhook_endpoint_id],
        body,
        opts
      )

  @doc "Replay events to an endpoint.\n\n`POST /v1/webhook_endpoints/{webhook_endpoint_id}/replay`"
  @spec replay_webhook_endpoint_events(
          Client.t(),
          String.t() | integer(),
          map() | binary(),
          keyword()
        ) :: Client.result()
  def replay_webhook_endpoint_events(client, webhook_endpoint_id, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:replay_webhook_endpoint_events),
        [webhook_endpoint_id],
        body,
        opts
      )

  @doc "Resume a webhook endpoint.\n\n`POST /v1/webhook_endpoints/{webhook_endpoint_id}/resume`"
  @spec resume_webhook_endpoint(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def resume_webhook_endpoint(client, webhook_endpoint_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:resume_webhook_endpoint),
        [webhook_endpoint_id],
        nil,
        opts
      )

  @doc "Retry messages in bulk.\n\n`POST /v1/webhook_endpoints/{webhook_endpoint_id}/retry`"
  @spec retry_webhook_endpoint_messages(
          Client.t(),
          String.t() | integer(),
          map() | binary(),
          keyword()
        ) :: Client.result()
  def retry_webhook_endpoint_messages(client, webhook_endpoint_id, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:retry_webhook_endpoint_messages),
        [webhook_endpoint_id],
        body,
        opts
      )

  @doc "Rotate a webhook endpoint's signing key.\n\n`POST /v1/webhook_endpoints/{webhook_endpoint_id}/rotate_key`\n\nThe body is optional and passed as `:body`."
  @spec rotate_webhook_endpoint_key(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def rotate_webhook_endpoint_key(client, webhook_endpoint_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:rotate_webhook_endpoint_key),
        [webhook_endpoint_id],
        nil,
        opts
      )

  @doc "Send a test event.\n\n`POST /v1/webhook_endpoints/{webhook_endpoint_id}/test`\n\nThe body is optional and passed as `:body`."
  @spec send_webhook_endpoint_test_event(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def send_webhook_endpoint_test_event(client, webhook_endpoint_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:send_webhook_endpoint_test_event),
        [webhook_endpoint_id],
        nil,
        opts
      )

  @doc "List the versions of an endpoint.\n\n`GET /v1/webhook_endpoints/{webhook_endpoint_id}/versions`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_webhook_endpoint_versions(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def list_webhook_endpoint_versions(client, webhook_endpoint_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:list_webhook_endpoint_versions),
        [webhook_endpoint_id],
        nil,
        opts
      )

  @doc "Get a version of an endpoint.\n\n`GET /v1/webhook_endpoints/{webhook_endpoint_id}/versions/{version}`"
  @spec get_webhook_endpoint_version(
          Client.t(),
          String.t() | integer(),
          String.t() | integer(),
          keyword()
        ) :: Client.result()
  def get_webhook_endpoint_version(client, webhook_endpoint_id, version, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_webhook_endpoint_version),
        [webhook_endpoint_id, version],
        nil,
        opts
      )

  @doc "List tenant event types.\n\n`GET /v1/webhook_event_types`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `state`."
  @spec list_webhook_event_types(Client.t(), keyword()) :: Client.result()
  def list_webhook_event_types(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_webhook_event_types), [], nil, opts)

  @doc "Create a tenant event type.\n\n`POST /v1/webhook_event_types`"
  @spec create_webhook_event_type(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_webhook_event_type(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_webhook_event_type), [], body, opts)

  @doc "Get a tenant event type.\n\n`GET /v1/webhook_event_types/{webhook_event_type_id}`"
  @spec get_webhook_event_type(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_webhook_event_type(client, webhook_event_type_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_webhook_event_type),
        [webhook_event_type_id],
        nil,
        opts
      )

  @doc "Archive a tenant event type.\n\n`POST /v1/webhook_event_types/{webhook_event_type_id}/archive`"
  @spec archive_webhook_event_type(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def archive_webhook_event_type(client, webhook_event_type_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:archive_webhook_event_type),
        [webhook_event_type_id],
        nil,
        opts
      )

  @doc "List the schema versions of a tenant event type.\n\n`GET /v1/webhook_event_types/{webhook_event_type_id}/versions`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_webhook_event_type_versions(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def list_webhook_event_type_versions(client, webhook_event_type_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:list_webhook_event_type_versions),
        [webhook_event_type_id],
        nil,
        opts
      )

  @doc "Add a schema version to a tenant event type.\n\n`POST /v1/webhook_event_types/{webhook_event_type_id}/versions`"
  @spec create_webhook_event_type_version(
          Client.t(),
          String.t() | integer(),
          map() | binary(),
          keyword()
        ) :: Client.result()
  def create_webhook_event_type_version(client, webhook_event_type_id, body, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:create_webhook_event_type_version),
        [webhook_event_type_id],
        body,
        opts
      )

  @doc "Get a schema version of a tenant event type.\n\n`GET /v1/webhook_event_types/{webhook_event_type_id}/versions/{version}`"
  @spec get_webhook_event_type_version(
          Client.t(),
          String.t() | integer(),
          String.t() | integer(),
          keyword()
        ) :: Client.result()
  def get_webhook_event_type_version(client, webhook_event_type_id, version, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_webhook_event_type_version),
        [webhook_event_type_id, version],
        nil,
        opts
      )

  @doc "List webhook events.\n\n`GET /v1/webhook_events`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `event_type`, `created_after`."
  @spec list_webhook_events(Client.t(), keyword()) :: Client.result()
  def list_webhook_events(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_webhook_events), [], nil, opts)

  @doc "List webhook messages.\n\n`GET /v1/webhook_messages`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `endpoint_id`, `event_id`, `state`, `event_type`, `created_after`, `created_before`."
  @spec list_webhook_messages(Client.t(), keyword()) :: Client.result()
  def list_webhook_messages(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_webhook_messages), [], nil, opts)

  @doc "Get a webhook message.\n\n`GET /v1/webhook_messages/{webhook_message_id}`"
  @spec get_webhook_message(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_webhook_message(client, webhook_message_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_webhook_message),
        [webhook_message_id],
        nil,
        opts
      )

  @doc "List the attempts of a message.\n\n`GET /v1/webhook_messages/{webhook_message_id}/attempts`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_webhook_message_attempts(Client.t(), String.t() | integer(), keyword()) ::
          Client.result()
  def list_webhook_message_attempts(client, webhook_message_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:list_webhook_message_attempts),
        [webhook_message_id],
        nil,
        opts
      )

  @doc "Get an attempt of a message.\n\n`GET /v1/webhook_messages/{webhook_message_id}/attempts/{webhook_attempt_id}`"
  @spec get_webhook_message_attempt(
          Client.t(),
          String.t() | integer(),
          String.t() | integer(),
          keyword()
        ) :: Client.result()
  def get_webhook_message_attempt(client, webhook_message_id, webhook_attempt_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_webhook_message_attempt),
        [webhook_message_id, webhook_attempt_id],
        nil,
        opts
      )

  @doc "Cancel a webhook message.\n\n`POST /v1/webhook_messages/{webhook_message_id}/cancel`"
  @spec cancel_webhook_message(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def cancel_webhook_message(client, webhook_message_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:cancel_webhook_message),
        [webhook_message_id],
        nil,
        opts
      )

  @doc "Resend a webhook message.\n\n`POST /v1/webhook_messages/{webhook_message_id}/resend`"
  @spec resend_webhook_message(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def resend_webhook_message(client, webhook_message_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:resend_webhook_message),
        [webhook_message_id],
        nil,
        opts
      )

  @doc "List completion sources.\n\n`GET /v1/webhook_sources`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`, `state`."
  @spec list_webhook_sources(Client.t(), keyword()) :: Client.result()
  def list_webhook_sources(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_webhook_sources), [], nil, opts)

  @doc "Register a completion source.\n\n`POST /v1/webhook_sources`"
  @spec create_webhook_source(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_webhook_source(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_webhook_source), [], body, opts)

  @doc "Get a completion source.\n\n`GET /v1/webhook_sources/{webhook_source_id}`"
  @spec get_webhook_source(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_webhook_source(client, webhook_source_id, opts \\ []),
    do:
      Client.call(client, Operations.fetch!(:get_webhook_source), [webhook_source_id], nil, opts)

  @doc "Archive a completion source.\n\n`POST /v1/webhook_sources/{webhook_source_id}/archive`"
  @spec archive_webhook_source(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def archive_webhook_source(client, webhook_source_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:archive_webhook_source),
        [webhook_source_id],
        nil,
        opts
      )

  @doc "List WhatsApp templates.\n\n`GET /v1/whatsapp/templates`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_whatsapp_templates(Client.t(), keyword()) :: Client.result()
  def list_whatsapp_templates(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_whatsapp_templates), [], nil, opts)

  @doc "Register a WhatsApp template.\n\n`POST /v1/whatsapp/templates`"
  @spec register_whatsapp_template(Client.t(), map() | binary(), keyword()) :: Client.result()
  def register_whatsapp_template(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:register_whatsapp_template), [], body, opts)

  @doc "Get a WhatsApp template.\n\n`GET /v1/whatsapp/templates/{whatsapp_template_id}`"
  @spec get_whatsapp_template(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_whatsapp_template(client, whatsapp_template_id, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_whatsapp_template),
        [whatsapp_template_id],
        nil,
        opts
      )

  @doc "List workflows.\n\n`GET /v1/workflows`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_workflows(Client.t(), keyword()) :: Client.result()
  def list_workflows(client, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_workflows), [], nil, opts)

  @doc "Create a workflow.\n\n`POST /v1/workflows`"
  @spec create_workflow(Client.t(), map() | binary(), keyword()) :: Client.result()
  def create_workflow(client, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:create_workflow), [], body, opts)

  @doc "Get a workflow.\n\n`GET /v1/workflows/{workflow_key}`"
  @spec get_workflow(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def get_workflow(client, workflow_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:get_workflow), [workflow_key], nil, opts)

  @doc "Replace the workflow draft.\n\n`PUT /v1/workflows/{workflow_key}`"
  @spec replace_workflow_draft(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def replace_workflow_draft(client, workflow_key, body, opts \\ []),
    do:
      Client.call(client, Operations.fetch!(:replace_workflow_draft), [workflow_key], body, opts)

  @doc "Change the workflow manager.\n\n`POST /v1/workflows/{workflow_key}/manager`"
  @spec set_workflow_manager(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def set_workflow_manager(client, workflow_key, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:set_workflow_manager), [workflow_key], body, opts)

  @doc "Preview a workflow.\n\n`POST /v1/workflows/{workflow_key}/preview`"
  @spec preview_workflow(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def preview_workflow(client, workflow_key, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:preview_workflow), [workflow_key], body, opts)

  @doc "Publish the draft.\n\n`POST /v1/workflows/{workflow_key}/publish`\n\nThe body is optional and passed as `:body`."
  @spec publish_workflow(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def publish_workflow(client, workflow_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:publish_workflow), [workflow_key], nil, opts)

  @doc "Test send a workflow.\n\n`POST /v1/workflows/{workflow_key}/test`"
  @spec send_workflow_test(Client.t(), String.t() | integer(), map() | binary(), keyword()) ::
          Client.result()
  def send_workflow_test(client, workflow_key, body, opts \\ []),
    do: Client.call(client, Operations.fetch!(:send_workflow_test), [workflow_key], body, opts)

  @doc "List published versions.\n\n`GET /v1/workflows/{workflow_key}/versions`, returns a page.\n\nQuery: `limit`, `starting_after`, `ending_before`."
  @spec list_workflow_versions(Client.t(), String.t() | integer(), keyword()) :: Client.result()
  def list_workflow_versions(client, workflow_key, opts \\ []),
    do: Client.call(client, Operations.fetch!(:list_workflow_versions), [workflow_key], nil, opts)

  @doc "Get a published version.\n\n`GET /v1/workflows/{workflow_key}/versions/{version}`"
  @spec get_workflow_version(
          Client.t(),
          String.t() | integer(),
          String.t() | integer(),
          keyword()
        ) :: Client.result()
  def get_workflow_version(client, workflow_key, version, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_workflow_version),
        [workflow_key, version],
        nil,
        opts
      )

  @doc "Export a published version as Mermaid.\n\n`GET /v1/workflows/{workflow_key}/versions/{version}/mermaid`"
  @spec get_workflow_version_mermaid(
          Client.t(),
          String.t() | integer(),
          String.t() | integer(),
          keyword()
        ) :: Client.result()
  def get_workflow_version_mermaid(client, workflow_key, version, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:get_workflow_version_mermaid),
        [workflow_key, version],
        nil,
        opts
      )

  @doc "Republish an earlier version.\n\n`POST /v1/workflows/{workflow_key}/versions/{version}/promote`"
  @spec promote_workflow_version(
          Client.t(),
          String.t() | integer(),
          String.t() | integer(),
          keyword()
        ) :: Client.result()
  def promote_workflow_version(client, workflow_key, version, opts \\ []),
    do:
      Client.call(
        client,
        Operations.fetch!(:promote_workflow_version),
        [workflow_key, version],
        nil,
        opts
      )
end
