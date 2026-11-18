#nullable enable

using System.Text.Json.Nodes;

namespace Esuiss.Relay;

/// <summary>One method for every operation of the Relay server API.</summary>
public sealed partial class RelayApi
{
    /// <summary>Send an event</summary>
    public Task<JsonNode> CreateEventAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateEvent, [], query, body, options, cancellationToken);
    }

    /// <summary>Send a batch of events</summary>
    public Task<JsonNode> CreateEventBatchAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateEventBatch, [], query, body, options, cancellationToken);
    }

    /// <summary>Get an event</summary>
    public Task<JsonNode> GetEventAsync(
        string eventId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetEvent, [eventId], query, null, options, cancellationToken);
    }

    /// <summary>Cancel an event</summary>
    public Task<JsonNode> CancelEventAsync(
        string eventId,
        JsonNode? body = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CancelEvent, [eventId], query, body, options, cancellationToken);
    }

    /// <summary>Cancel by cancellation key</summary>
    public Task<JsonNode> CancelEventsByKeyAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CancelEventsByKey, [], query, body, options, cancellationToken);
    }

    /// <summary>List notifications</summary>
    public Task<Page> ListNotificationsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? subscriber = null,
        string? workflow = null,
        string? status = null,
        string? createdAfter = null,
        string? createdBefore = null,
        bool? isTest = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("subscriber", subscriber);
        query.Add("workflow", workflow);
        query.Add("status", status);
        query.Add("created_after", createdAfter);
        query.Add("created_before", createdBefore);
        query.Add("is_test", isTest);
        return _client.ListAsync(Operations.ListNotifications, [], query, null, options, cancellationToken);
    }

    /// <summary>Get a notification</summary>
    public Task<JsonNode> GetNotificationAsync(
        string notificationId,
        IEnumerable<string>? expand = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("expand", expand);
        return _client.SendJsonAsync(Operations.GetNotification, [notificationId], query, null, options, cancellationToken);
    }

    /// <summary>Cancel a notification</summary>
    public Task<JsonNode> CancelNotificationAsync(
        string notificationId,
        JsonNode? body = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CancelNotification, [notificationId], query, body, options, cancellationToken);
    }

    /// <summary>List deliveries of a notification</summary>
    public Task<Page> ListNotificationDeliveriesAsync(
        string notificationId,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListNotificationDeliveries, [notificationId], query, null, options, cancellationToken);
    }

    /// <summary>Get attempt history and ledger of a delivery</summary>
    public Task<JsonNode> GetDeliveryHistoryAsync(
        string deliveryId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetDeliveryHistory, [deliveryId], query, null, options, cancellationToken);
    }

    /// <summary>Explain why a subscriber did or did not get notifications</summary>
    public Task<Page> ListSubscriberDecisionsAsync(
        string subscriberId,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? createdAfter = null,
        string? createdBefore = null,
        string? workflow = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("created_after", createdAfter);
        query.Add("created_before", createdBefore);
        query.Add("workflow", workflow);
        return _client.ListAsync(Operations.ListSubscriberDecisions, [subscriberId], query, null, options, cancellationToken);
    }

    /// <summary>Create a subscriber</summary>
    public Task<JsonNode> CreateSubscriberAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateSubscriber, [], query, body, options, cancellationToken);
    }

    /// <summary>List subscribers</summary>
    public Task<Page> ListSubscribersAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListSubscribers, [], query, null, options, cancellationToken);
    }

    /// <summary>Get a subscriber</summary>
    public Task<JsonNode> GetSubscriberAsync(
        string subscriberId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetSubscriber, [subscriberId], query, null, options, cancellationToken);
    }

    /// <summary>Create or replace a subscriber</summary>
    public Task<JsonNode> ReplaceSubscriberAsync(
        string subscriberId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ReplaceSubscriber, [subscriberId], query, body, options, cancellationToken);
    }

    /// <summary>Update a subscriber</summary>
    public Task<JsonNode> UpdateSubscriberAsync(
        string subscriberId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.UpdateSubscriber, [subscriberId], query, body, options, cancellationToken);
    }

    /// <summary>Request deletion of a subscriber</summary>
    public Task<JsonNode> DeleteSubscriberAsync(
        string subscriberId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.DeleteSubscriber, [subscriberId], query, null, options, cancellationToken);
    }

    /// <summary>Bulk upsert subscribers</summary>
    public Task<JsonNode> BulkUpsertSubscribersAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.BulkUpsertSubscribers, [], query, body, options, cancellationToken);
    }

    /// <summary>Get subscriber preferences</summary>
    public Task<JsonNode> GetSubscriberPreferencesAsync(
        string subscriberId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetSubscriberPreferences, [subscriberId], query, null, options, cancellationToken);
    }

    /// <summary>Update subscriber preferences</summary>
    public Task<JsonNode> UpdateSubscriberPreferencesAsync(
        string subscriberId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.UpdateSubscriberPreferences, [subscriberId], query, body, options, cancellationToken);
    }

    /// <summary>Mint a hosted preference page link</summary>
    public Task<JsonNode> CreatePreferencePageLinkAsync(
        string subscriberId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreatePreferencePageLink, [subscriberId], query, null, options, cancellationToken);
    }

    /// <summary>List subscriber consents</summary>
    public Task<Page> ListSubscriberConsentsAsync(
        string subscriberId,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListSubscriberConsents, [subscriberId], query, null, options, cancellationToken);
    }

    /// <summary>List subscriber devices</summary>
    public Task<Page> ListSubscriberDevicesAsync(
        string subscriberId,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListSubscriberDevices, [subscriberId], query, null, options, cancellationToken);
    }

    /// <summary>Register a subscriber device</summary>
    public Task<JsonNode> RegisterSubscriberDeviceAsync(
        string subscriberId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.RegisterSubscriberDevice, [subscriberId], query, body, options, cancellationToken);
    }

    /// <summary>Remove a subscriber device</summary>
    public Task<JsonNode> DeleteSubscriberDeviceAsync(
        string subscriberId,
        string deviceId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.DeleteSubscriberDevice, [subscriberId, deviceId], query, null, options, cancellationToken);
    }

    /// <summary>Remove a device by its token</summary>
    public Task<JsonNode> DeleteDeviceByTokenAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.DeleteDeviceByToken, [], query, body, options, cancellationToken);
    }

    /// <summary>Get the jitter control</summary>
    public Task<JsonNode> GetTimingSettingsAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetTimingSettings, [], query, null, options, cancellationToken);
    }

    /// <summary>Set the jitter control</summary>
    public Task<JsonNode> SetTimingSettingsAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.SetTimingSettings, [], query, body, options, cancellationToken);
    }

    /// <summary>Get the allowed browser origins</summary>
    public Task<JsonNode> GetRealtimeOriginsAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetRealtimeOrigins, [], query, null, options, cancellationToken);
    }

    /// <summary>Set the allowed browser origins</summary>
    public Task<JsonNode> SetRealtimeOriginsAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.SetRealtimeOrigins, [], query, body, options, cancellationToken);
    }

    /// <summary>List routes</summary>
    public Task<Page> ListRoutesAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListRoutes, [], query, null, options, cancellationToken);
    }

    /// <summary>Create a route</summary>
    public Task<JsonNode> CreateRouteAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateRoute, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a route</summary>
    public Task<JsonNode> GetRouteAsync(
        string routeKey,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetRoute, [routeKey], query, null, options, cancellationToken);
    }

    /// <summary>Replace a route</summary>
    public Task<JsonNode> ReplaceRouteAsync(
        string routeKey,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ReplaceRoute, [routeKey], query, body, options, cancellationToken);
    }

    /// <summary>Archive a route</summary>
    public Task<JsonNode> ArchiveRouteAsync(
        string routeKey,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ArchiveRoute, [routeKey], query, null, options, cancellationToken);
    }

    /// <summary>List workflows</summary>
    public Task<Page> ListWorkflowsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListWorkflows, [], query, null, options, cancellationToken);
    }

    /// <summary>Create a workflow</summary>
    public Task<JsonNode> CreateWorkflowAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateWorkflow, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a workflow</summary>
    public Task<JsonNode> GetWorkflowAsync(
        string workflowKey,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetWorkflow, [workflowKey], query, null, options, cancellationToken);
    }

    /// <summary>Replace the workflow draft</summary>
    public Task<JsonNode> ReplaceWorkflowDraftAsync(
        string workflowKey,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ReplaceWorkflowDraft, [workflowKey], query, body, options, cancellationToken);
    }

    /// <summary>Publish the draft</summary>
    public Task<JsonNode> PublishWorkflowAsync(
        string workflowKey,
        JsonNode? body = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.PublishWorkflow, [workflowKey], query, body, options, cancellationToken);
    }

    /// <summary>Change the workflow manager</summary>
    public Task<JsonNode> SetWorkflowManagerAsync(
        string workflowKey,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.SetWorkflowManager, [workflowKey], query, body, options, cancellationToken);
    }

    /// <summary>List published versions</summary>
    public Task<Page> ListWorkflowVersionsAsync(
        string workflowKey,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListWorkflowVersions, [workflowKey], query, null, options, cancellationToken);
    }

    /// <summary>Get a published version</summary>
    public Task<JsonNode> GetWorkflowVersionAsync(
        string workflowKey,
        string version,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetWorkflowVersion, [workflowKey, version], query, null, options, cancellationToken);
    }

    /// <summary>Export a published version as Mermaid</summary>
    public Task<string> GetWorkflowVersionMermaidAsync(
        string workflowKey,
        string version,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendTextAsync(Operations.GetWorkflowVersionMermaid, [workflowKey, version], query, null, options, cancellationToken);
    }

    /// <summary>Republish an earlier version</summary>
    public Task<JsonNode> PromoteWorkflowVersionAsync(
        string workflowKey,
        string version,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.PromoteWorkflowVersion, [workflowKey, version], query, null, options, cancellationToken);
    }

    /// <summary>Preview a workflow</summary>
    public Task<JsonNode> PreviewWorkflowAsync(
        string workflowKey,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.PreviewWorkflow, [workflowKey], query, body, options, cancellationToken);
    }

    /// <summary>Test send a workflow</summary>
    public Task<JsonNode> SendWorkflowTestAsync(
        string workflowKey,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.SendWorkflowTest, [workflowKey], query, body, options, cancellationToken);
    }

    /// <summary>List templates</summary>
    public Task<Page> ListTemplatesAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("subtenant", subtenant);
        return _client.ListAsync(Operations.ListTemplates, [], query, null, options, cancellationToken);
    }

    /// <summary>Create a template</summary>
    public Task<JsonNode> CreateTemplateAsync(
        JsonNode body,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.CreateTemplate, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a template</summary>
    public Task<JsonNode> GetTemplateAsync(
        string templateKey,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.GetTemplate, [templateKey], query, null, options, cancellationToken);
    }

    /// <summary>Replace the template draft</summary>
    public Task<JsonNode> ReplaceTemplateDraftAsync(
        string templateKey,
        JsonNode body,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.ReplaceTemplateDraft, [templateKey], query, body, options, cancellationToken);
    }

    /// <summary>Publish the draft</summary>
    public Task<JsonNode> PublishTemplateAsync(
        string templateKey,
        JsonNode? body = null,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.PublishTemplate, [templateKey], query, body, options, cancellationToken);
    }

    /// <summary>Archive the template</summary>
    public Task<JsonNode> ArchiveTemplateAsync(
        string templateKey,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.ArchiveTemplate, [templateKey], query, null, options, cancellationToken);
    }

    /// <summary>List template versions</summary>
    public Task<Page> ListTemplateVersionsAsync(
        string templateKey,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("subtenant", subtenant);
        return _client.ListAsync(Operations.ListTemplateVersions, [templateKey], query, null, options, cancellationToken);
    }

    /// <summary>Get a template version</summary>
    public Task<JsonNode> GetTemplateVersionAsync(
        string templateKey,
        string version,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.GetTemplateVersion, [templateKey, version], query, null, options, cancellationToken);
    }

    /// <summary>Roll back to a version</summary>
    public Task<JsonNode> PromoteTemplateVersionAsync(
        string templateKey,
        string version,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.PromoteTemplateVersion, [templateKey, version], query, null, options, cancellationToken);
    }

    /// <summary>Get the translation matrix</summary>
    public Task<JsonNode> GetTemplateTranslationsAsync(
        string templateKey,
        string? source = null,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("source", source);
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.GetTemplateTranslations, [templateKey], query, null, options, cancellationToken);
    }

    /// <summary>Preview a template</summary>
    public Task<JsonNode> PreviewTemplateAsync(
        string templateKey,
        JsonNode body,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.PreviewTemplate, [templateKey], query, body, options, cancellationToken);
    }

    /// <summary>Publish a producer template</summary>
    public Task<JsonNode> PublishProducerTemplateAsync(
        string templateKey,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.PublishProducerTemplate, [templateKey], query, body, options, cancellationToken);
    }

    /// <summary>List layouts</summary>
    public Task<Page> ListLayoutsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("subtenant", subtenant);
        return _client.ListAsync(Operations.ListLayouts, [], query, null, options, cancellationToken);
    }

    /// <summary>Create a layout</summary>
    public Task<JsonNode> CreateLayoutAsync(
        JsonNode body,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.CreateLayout, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a layout</summary>
    public Task<JsonNode> GetLayoutAsync(
        string layoutKey,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.GetLayout, [layoutKey], query, null, options, cancellationToken);
    }

    /// <summary>Replace the layout draft</summary>
    public Task<JsonNode> ReplaceLayoutDraftAsync(
        string layoutKey,
        JsonNode body,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.ReplaceLayoutDraft, [layoutKey], query, body, options, cancellationToken);
    }

    /// <summary>Publish the draft</summary>
    public Task<JsonNode> PublishLayoutAsync(
        string layoutKey,
        JsonNode? body = null,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.PublishLayout, [layoutKey], query, body, options, cancellationToken);
    }

    /// <summary>Archive the layout</summary>
    public Task<JsonNode> ArchiveLayoutAsync(
        string layoutKey,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.ArchiveLayout, [layoutKey], query, null, options, cancellationToken);
    }

    /// <summary>List layout versions</summary>
    public Task<Page> ListLayoutVersionsAsync(
        string layoutKey,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("subtenant", subtenant);
        return _client.ListAsync(Operations.ListLayoutVersions, [layoutKey], query, null, options, cancellationToken);
    }

    /// <summary>Get a layout version</summary>
    public Task<JsonNode> GetLayoutVersionAsync(
        string layoutKey,
        string version,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.GetLayoutVersion, [layoutKey, version], query, null, options, cancellationToken);
    }

    /// <summary>Roll back to a version</summary>
    public Task<JsonNode> PromoteLayoutVersionAsync(
        string layoutKey,
        string version,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.PromoteLayoutVersion, [layoutKey, version], query, null, options, cancellationToken);
    }

    /// <summary>List partials</summary>
    public Task<Page> ListPartialsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("subtenant", subtenant);
        return _client.ListAsync(Operations.ListPartials, [], query, null, options, cancellationToken);
    }

    /// <summary>Create a partial</summary>
    public Task<JsonNode> CreatePartialAsync(
        JsonNode body,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.CreatePartial, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a partial</summary>
    public Task<JsonNode> GetPartialAsync(
        string partialKey,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.GetPartial, [partialKey], query, null, options, cancellationToken);
    }

    /// <summary>Replace the partial draft</summary>
    public Task<JsonNode> ReplacePartialDraftAsync(
        string partialKey,
        JsonNode body,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.ReplacePartialDraft, [partialKey], query, body, options, cancellationToken);
    }

    /// <summary>Publish the draft</summary>
    public Task<JsonNode> PublishPartialAsync(
        string partialKey,
        JsonNode? body = null,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.PublishPartial, [partialKey], query, body, options, cancellationToken);
    }

    /// <summary>Archive the partial</summary>
    public Task<JsonNode> ArchivePartialAsync(
        string partialKey,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.ArchivePartial, [partialKey], query, null, options, cancellationToken);
    }

    /// <summary>List partial versions</summary>
    public Task<Page> ListPartialVersionsAsync(
        string partialKey,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("subtenant", subtenant);
        return _client.ListAsync(Operations.ListPartialVersions, [partialKey], query, null, options, cancellationToken);
    }

    /// <summary>Get a partial version</summary>
    public Task<JsonNode> GetPartialVersionAsync(
        string partialKey,
        string version,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.GetPartialVersion, [partialKey, version], query, null, options, cancellationToken);
    }

    /// <summary>Roll back to a version</summary>
    public Task<JsonNode> PromotePartialVersionAsync(
        string partialKey,
        string version,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.PromotePartialVersion, [partialKey, version], query, null, options, cancellationToken);
    }

    /// <summary>Get the brand settings</summary>
    public Task<JsonNode> GetBrandAsync(
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.GetBrand, [], query, null, options, cancellationToken);
    }

    /// <summary>Update the brand settings</summary>
    public Task<JsonNode> UpdateBrandAsync(
        JsonNode body,
        string? subtenant = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("subtenant", subtenant);
        return _client.SendJsonAsync(Operations.UpdateBrand, [], query, body, options, cancellationToken);
    }

    /// <summary>Get the compliance settings</summary>
    public Task<JsonNode> GetComplianceSettingsAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetComplianceSettings, [], query, null, options, cancellationToken);
    }

    /// <summary>Replace the tenant compliance settings</summary>
    public Task<JsonNode> ReplaceComplianceSettingsAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ReplaceComplianceSettings, [], query, body, options, cancellationToken);
    }

    /// <summary>Get the DLR windows</summary>
    public Task<JsonNode> GetDeliveryWindowsAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetDeliveryWindows, [], query, null, options, cancellationToken);
    }

    /// <summary>Replace the tenant DLR windows</summary>
    public Task<JsonNode> ReplaceDeliveryWindowsAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ReplaceDeliveryWindows, [], query, body, options, cancellationToken);
    }

    /// <summary>List CloudEvents type mappings</summary>
    public Task<Page> ListEventTypeMappingsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListEventTypeMappings, [], query, null, options, cancellationToken);
    }

    /// <summary>Create a CloudEvents type mapping</summary>
    public Task<JsonNode> CreateEventTypeMappingAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateEventTypeMapping, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a CloudEvents type mapping</summary>
    public Task<JsonNode> GetEventTypeMappingAsync(
        string mappingId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetEventTypeMapping, [mappingId], query, null, options, cancellationToken);
    }

    /// <summary>Replace a CloudEvents type mapping</summary>
    public Task<JsonNode> ReplaceEventTypeMappingAsync(
        string mappingId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ReplaceEventTypeMapping, [mappingId], query, body, options, cancellationToken);
    }

    /// <summary>Archive a CloudEvents type mapping</summary>
    public Task<JsonNode> ArchiveEventTypeMappingAsync(
        string mappingId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ArchiveEventTypeMapping, [mappingId], query, null, options, cancellationToken);
    }

    /// <summary>List categories</summary>
    public Task<Page> ListCategoriesAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListCategories, [], query, null, options, cancellationToken);
    }

    /// <summary>Create a category</summary>
    public Task<JsonNode> CreateCategoryAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateCategory, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a category</summary>
    public Task<JsonNode> GetCategoryAsync(
        string categoryKey,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetCategory, [categoryKey], query, null, options, cancellationToken);
    }

    /// <summary>Update a category</summary>
    public Task<JsonNode> UpdateCategoryAsync(
        string categoryKey,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.UpdateCategory, [categoryKey], query, body, options, cancellationToken);
    }

    /// <summary>Archive a category</summary>
    public Task<JsonNode> ArchiveCategoryAsync(
        string categoryKey,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ArchiveCategory, [categoryKey], query, null, options, cancellationToken);
    }

    /// <summary>Get a subtenant setting of a category</summary>
    public Task<JsonNode> GetCategorySubtenantSettingAsync(
        string categoryKey,
        string subtenantId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetCategorySubtenantSetting, [categoryKey, subtenantId], query, null, options, cancellationToken);
    }

    /// <summary>Set a subtenant setting of a category</summary>
    public Task<JsonNode> ReplaceCategorySubtenantSettingAsync(
        string categoryKey,
        string subtenantId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ReplaceCategorySubtenantSetting, [categoryKey, subtenantId], query, body, options, cancellationToken);
    }

    /// <summary>Get the e-mail tracking of a category</summary>
    public Task<JsonNode> GetCategoryEmailTrackingAsync(
        string categoryKey,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetCategoryEmailTracking, [categoryKey], query, null, options, cancellationToken);
    }

    /// <summary>Set the e-mail tracking of a category</summary>
    public Task<JsonNode> ReplaceCategoryEmailTrackingAsync(
        string categoryKey,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ReplaceCategoryEmailTracking, [categoryKey], query, body, options, cancellationToken);
    }

    /// <summary>Get the e-mail tracking of a template</summary>
    public Task<JsonNode> GetTemplateEmailTrackingAsync(
        string templateKey,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetTemplateEmailTracking, [templateKey], query, null, options, cancellationToken);
    }

    /// <summary>Set the e-mail tracking of a template</summary>
    public Task<JsonNode> ReplaceTemplateEmailTrackingAsync(
        string templateKey,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ReplaceTemplateEmailTracking, [templateKey], query, body, options, cancellationToken);
    }

    /// <summary>List suppressions</summary>
    public Task<Page> ListSuppressionsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? channel = null,
        string? reason = null,
        string? state = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("channel", channel);
        query.Add("reason", reason);
        query.Add("state", state);
        return _client.ListAsync(Operations.ListSuppressions, [], query, null, options, cancellationToken);
    }

    /// <summary>Add a suppression</summary>
    public Task<JsonNode> CreateSuppressionAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateSuppression, [], query, body, options, cancellationToken);
    }

    /// <summary>Lift a suppression</summary>
    public Task<JsonNode> LiftSuppressionAsync(
        string suppressionId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.LiftSuppression, [suppressionId], query, body, options, cancellationToken);
    }

    /// <summary>Get the SMS destination policy</summary>
    public Task<JsonNode> GetSmsDestinationPolicyAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetSmsDestinationPolicy, [], query, null, options, cancellationToken);
    }

    /// <summary>Set the SMS destination policy</summary>
    public Task<JsonNode> SetSmsDestinationPolicyAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.SetSmsDestinationPolicy, [], query, body, options, cancellationToken);
    }

    /// <summary>List SMS destination stops</summary>
    public Task<Page> ListSmsDestinationStopsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? state = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("state", state);
        return _client.ListAsync(Operations.ListSmsDestinationStops, [], query, null, options, cancellationToken);
    }

    /// <summary>Lift an SMS destination stop</summary>
    public Task<JsonNode> LiftSmsDestinationStopAsync(
        string smsDestinationStopId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.LiftSmsDestinationStop, [smsDestinationStopId], query, body, options, cancellationToken);
    }

    /// <summary>List test recipients</summary>
    public Task<JsonNode> ListTestRecipientsAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ListTestRecipients, [], query, null, options, cancellationToken);
    }

    /// <summary>Add a test recipient</summary>
    public Task<JsonNode> CreateTestRecipientAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateTestRecipient, [], query, body, options, cancellationToken);
    }

    /// <summary>Remove a test recipient</summary>
    public Task<JsonNode> RemoveTestRecipientAsync(
        string testRecipientId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.RemoveTestRecipient, [testRecipientId], query, null, options, cancellationToken);
    }

    /// <summary>Publish an inbox announcement</summary>
    public Task<JsonNode> CreateInboxAnnouncementAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateInboxAnnouncement, [], query, body, options, cancellationToken);
    }

    /// <summary>Get an inbox announcement</summary>
    public Task<JsonNode> GetInboxAnnouncementAsync(
        string announcementId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetInboxAnnouncement, [announcementId], query, null, options, cancellationToken);
    }

    /// <summary>Retract an inbox announcement</summary>
    public Task<JsonNode> RetractInboxAnnouncementAsync(
        string announcementId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.RetractInboxAnnouncement, [announcementId], query, null, options, cancellationToken);
    }

    /// <summary>List topics</summary>
    public Task<Page> ListTopicsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListTopics, [], query, null, options, cancellationToken);
    }

    /// <summary>Create a topic</summary>
    public Task<JsonNode> CreateTopicAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateTopic, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a topic</summary>
    public Task<JsonNode> GetTopicAsync(
        string topicKey,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetTopic, [topicKey], query, null, options, cancellationToken);
    }

    /// <summary>Archive a topic</summary>
    public Task<JsonNode> ArchiveTopicAsync(
        string topicKey,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ArchiveTopic, [topicKey], query, null, options, cancellationToken);
    }

    /// <summary>List the subscriptions of a topic</summary>
    public Task<Page> ListTopicSubscriptionsAsync(
        string topicKey,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListTopicSubscriptions, [topicKey], query, null, options, cancellationToken);
    }

    /// <summary>Subscribe subscribers to a topic</summary>
    public Task<JsonNode> AddTopicSubscriptionsAsync(
        string topicKey,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.AddTopicSubscriptions, [topicKey], query, body, options, cancellationToken);
    }

    /// <summary>Unsubscribe subscribers from a topic</summary>
    public Task<JsonNode> RemoveTopicSubscriptionsAsync(
        string topicKey,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.RemoveTopicSubscriptions, [topicKey], query, body, options, cancellationToken);
    }

    /// <summary>List the topics a subscriber is subscribed to</summary>
    public Task<Page> ListSubscriberSubscriptionsAsync(
        string subscriberId,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListSubscriberSubscriptions, [subscriberId], query, null, options, cancellationToken);
    }

    /// <summary>List kill switches</summary>
    public Task<Page> ListKillSwitchesAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        bool? includeReleased = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("include_released", includeReleased);
        return _client.ListAsync(Operations.ListKillSwitches, [], query, null, options, cancellationToken);
    }

    /// <summary>Engage a kill switch</summary>
    public Task<JsonNode> EngageKillSwitchAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.EngageKillSwitch, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a kill switch</summary>
    public Task<JsonNode> GetKillSwitchAsync(
        string killSwitchId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetKillSwitch, [killSwitchId], query, null, options, cancellationToken);
    }

    /// <summary>Replace the state of a kill switch</summary>
    public Task<JsonNode> ReplaceKillSwitchAsync(
        string killSwitchId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ReplaceKillSwitch, [killSwitchId], query, body, options, cancellationToken);
    }

    /// <summary>Get the virtual clock</summary>
    public Task<JsonNode> GetVirtualClockAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetVirtualClock, [], query, null, options, cancellationToken);
    }

    /// <summary>Advance the virtual clock</summary>
    public Task<JsonNode> AdvanceVirtualClockAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.AdvanceVirtualClock, [], query, body, options, cancellationToken);
    }

    /// <summary>List the simulated results of the fake provider</summary>
    public Task<JsonNode> ListSimulatedResultsAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ListSimulatedResults, [], query, null, options, cancellationToken);
    }

    /// <summary>List the seed recipients of the test plane</summary>
    public Task<JsonNode> ListSeedRecipientsAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ListSeedRecipients, [], query, null, options, cancellationToken);
    }

    /// <summary>Reset the seed recipients of the test plane</summary>
    public Task<JsonNode> ResetSeedRecipientsAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ResetSeedRecipients, [], query, null, options, cancellationToken);
    }

    /// <summary>List the test inbox</summary>
    public Task<Page> ListTestInboxMessagesAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListTestInboxMessages, [], query, null, options, cancellationToken);
    }

    /// <summary>List waitpoints</summary>
    public Task<Page> ListWaitpointsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? state = null,
        bool? awaitingResponse = null,
        string? waiter = null,
        string? tag = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("state", state);
        query.Add("awaiting_response", awaitingResponse);
        query.Add("waiter", waiter);
        query.Add("tag", tag);
        return _client.ListAsync(Operations.ListWaitpoints, [], query, null, options, cancellationToken);
    }

    /// <summary>Create a waitpoint</summary>
    public Task<JsonNode> CreateWaitpointAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateWaitpoint, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a waitpoint</summary>
    public Task<JsonNode> GetWaitpointAsync(
        string waitpointId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetWaitpoint, [waitpointId], query, null, options, cancellationToken);
    }

    /// <summary>Cancel a waitpoint</summary>
    public Task<JsonNode> CancelWaitpointAsync(
        string waitpointId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CancelWaitpoint, [waitpointId], query, body, options, cancellationToken);
    }

    /// <summary>Send a waiter heartbeat</summary>
    public Task<JsonNode> HeartbeatWaitpointAsync(
        string waitpointId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.HeartbeatWaitpoint, [waitpointId], query, null, options, cancellationToken);
    }

    /// <summary>Get the caller's mailbox</summary>
    public Task<JsonNode> GetMailboxAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetMailbox, [], query, null, options, cancellationToken);
    }

    /// <summary>Lease mailbox records</summary>
    public Task<JsonNode> LeaseMailboxRecordsAsync(
        JsonNode? body = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.LeaseMailboxRecords, [], query, body, options, cancellationToken);
    }

    /// <summary>Acknowledge mailbox records</summary>
    public Task<JsonNode> AckMailboxRecordsAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.AckMailboxRecords, [], query, body, options, cancellationToken);
    }

    /// <summary>Publish an AG-UI event</summary>
    public Task<JsonNode> PublishAgUiEventAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.PublishAgUiEvent, [], query, body, options, cancellationToken);
    }

    /// <summary>Call the MCP server</summary>
    public Task<JsonNode> CallMcpAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CallMcp, [], query, body, options, cancellationToken);
    }

    /// <summary>Read mailbox records in order</summary>
    public Task<JsonNode> ListMailboxRecordsAsync(
        string? since = null,
        int? limit = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("since", since);
        query.Add("limit", limit);
        return _client.SendJsonAsync(Operations.ListMailboxRecords, [], query, null, options, cancellationToken);
    }

    /// <summary>Get a mailbox record by its handle</summary>
    public Task<JsonNode> GetMailboxRecordAsync(
        string recordId,
        string? content = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("content", content);
        return _client.SendJsonAsync(Operations.GetMailboxRecord, [recordId], query, null, options, cancellationToken);
    }

    /// <summary>List dead-lettered mailbox records</summary>
    public Task<Page> ListMailboxDeadLettersAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? mailboxId = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("mailbox_id", mailboxId);
        return _client.ListAsync(Operations.ListMailboxDeadLetters, [], query, null, options, cancellationToken);
    }

    /// <summary>Send a message to an agent's mailbox</summary>
    public Task<JsonNode> SendMailboxMessageAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.SendMailboxMessage, [], query, body, options, cancellationToken);
    }

    /// <summary>List the request box</summary>
    public Task<Page> ListMailboxRequestsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListMailboxRequests, [], query, null, options, cancellationToken);
    }

    /// <summary>Read the encrypted envelope of a message</summary>
    public Task<JsonNode> GetMailboxEnvelopeAsync(
        string recordId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("record_id", recordId);
        return _client.SendJsonAsync(Operations.GetMailboxEnvelope, [], query, null, options, cancellationToken);
    }

    /// <summary>Block or unblock a sender</summary>
    public Task<JsonNode> SetMailboxSenderBlockAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.SetMailboxSenderBlock, [], query, body, options, cancellationToken);
    }

    /// <summary>Report a mailbox message as abuse</summary>
    public Task<JsonNode> ReportMailboxAbuseAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ReportMailboxAbuse, [], query, body, options, cancellationToken);
    }

    /// <summary>List escalation policies</summary>
    public Task<Page> ListEscalationPoliciesAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? state = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("state", state);
        return _client.ListAsync(Operations.ListEscalationPolicies, [], query, null, options, cancellationToken);
    }

    /// <summary>Get an escalation policy</summary>
    public Task<JsonNode> GetEscalationPolicyAsync(
        string policyKey,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetEscalationPolicy, [policyKey], query, null, options, cancellationToken);
    }

    /// <summary>Write an escalation policy version</summary>
    public Task<JsonNode> PutEscalationPolicyAsync(
        string policyKey,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.PutEscalationPolicy, [policyKey], query, body, options, cancellationToken);
    }

    /// <summary>List escalation policy versions</summary>
    public Task<Page> ListEscalationPolicyVersionsAsync(
        string policyKey,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListEscalationPolicyVersions, [policyKey], query, null, options, cancellationToken);
    }

    /// <summary>Archive an escalation policy</summary>
    public Task<JsonNode> ArchiveEscalationPolicyAsync(
        string policyKey,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ArchiveEscalationPolicy, [policyKey], query, null, options, cancellationToken);
    }

    /// <summary>List agents</summary>
    public Task<Page> ListAgentsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListAgents, [], query, null, options, cancellationToken);
    }

    /// <summary>Create an agent</summary>
    public Task<JsonNode> CreateAgentAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateAgent, [], query, body, options, cancellationToken);
    }

    /// <summary>Get an agent</summary>
    public Task<JsonNode> GetAgentAsync(
        string agentId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetAgent, [agentId], query, null, options, cancellationToken);
    }

    /// <summary>Update an agent</summary>
    public Task<JsonNode> UpdateAgentAsync(
        string agentId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.UpdateAgent, [agentId], query, body, options, cancellationToken);
    }

    /// <summary>Delete an agent</summary>
    public Task<JsonNode> DeleteAgentAsync(
        string agentId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.DeleteAgent, [agentId], query, null, options, cancellationToken);
    }

    /// <summary>Decide on held agent notifications</summary>
    public Task<JsonNode> CreateAgentCeilingDecisionAsync(
        string agentId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateAgentCeilingDecision, [agentId], query, body, options, cancellationToken);
    }

    /// <summary>List held agent notifications</summary>
    public Task<Page> ListAgentCeilingHoldsAsync(
        string agentId,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? state = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("state", state);
        return _client.ListAsync(Operations.ListAgentCeilingHolds, [agentId], query, null, options, cancellationToken);
    }

    /// <summary>Resume a stopped agent</summary>
    public Task<JsonNode> ResumeAgentAsync(
        string agentId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ResumeAgent, [agentId], query, body, options, cancellationToken);
    }

    /// <summary>List webhook consumers</summary>
    public Task<Page> ListWebhookConsumersAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? state = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("state", state);
        return _client.ListAsync(Operations.ListWebhookConsumers, [], query, null, options, cancellationToken);
    }

    /// <summary>Create a webhook consumer</summary>
    public Task<JsonNode> CreateWebhookConsumerAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateWebhookConsumer, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a webhook consumer</summary>
    public Task<JsonNode> GetWebhookConsumerAsync(
        string webhookConsumerId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetWebhookConsumer, [webhookConsumerId], query, null, options, cancellationToken);
    }

    /// <summary>Update a webhook consumer</summary>
    public Task<JsonNode> UpdateWebhookConsumerAsync(
        string webhookConsumerId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.UpdateWebhookConsumer, [webhookConsumerId], query, body, options, cancellationToken);
    }

    /// <summary>Archive a webhook consumer</summary>
    public Task<JsonNode> ArchiveWebhookConsumerAsync(
        string webhookConsumerId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ArchiveWebhookConsumer, [webhookConsumerId], query, null, options, cancellationToken);
    }

    /// <summary>List completion sources</summary>
    public Task<Page> ListWebhookSourcesAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? state = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("state", state);
        return _client.ListAsync(Operations.ListWebhookSources, [], query, null, options, cancellationToken);
    }

    /// <summary>Register a completion source</summary>
    public Task<JsonNode> CreateWebhookSourceAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateWebhookSource, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a completion source</summary>
    public Task<JsonNode> GetWebhookSourceAsync(
        string webhookSourceId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetWebhookSource, [webhookSourceId], query, null, options, cancellationToken);
    }

    /// <summary>Archive a completion source</summary>
    public Task<JsonNode> ArchiveWebhookSourceAsync(
        string webhookSourceId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ArchiveWebhookSource, [webhookSourceId], query, null, options, cancellationToken);
    }

    /// <summary>Mint a webhook portal token</summary>
    public Task<JsonNode> CreateWebhookPortalTokenAsync(
        string webhookConsumerId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateWebhookPortalToken, [webhookConsumerId], query, null, options, cancellationToken);
    }

    /// <summary>List tenant event types</summary>
    public Task<Page> ListWebhookEventTypesAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? state = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("state", state);
        return _client.ListAsync(Operations.ListWebhookEventTypes, [], query, null, options, cancellationToken);
    }

    /// <summary>Create a tenant event type</summary>
    public Task<JsonNode> CreateWebhookEventTypeAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateWebhookEventType, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a tenant event type</summary>
    public Task<JsonNode> GetWebhookEventTypeAsync(
        string webhookEventTypeId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetWebhookEventType, [webhookEventTypeId], query, null, options, cancellationToken);
    }

    /// <summary>Archive a tenant event type</summary>
    public Task<JsonNode> ArchiveWebhookEventTypeAsync(
        string webhookEventTypeId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ArchiveWebhookEventType, [webhookEventTypeId], query, null, options, cancellationToken);
    }

    /// <summary>List the schema versions of a tenant event type</summary>
    public Task<Page> ListWebhookEventTypeVersionsAsync(
        string webhookEventTypeId,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListWebhookEventTypeVersions, [webhookEventTypeId], query, null, options, cancellationToken);
    }

    /// <summary>Add a schema version to a tenant event type</summary>
    public Task<JsonNode> CreateWebhookEventTypeVersionAsync(
        string webhookEventTypeId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateWebhookEventTypeVersion, [webhookEventTypeId], query, body, options, cancellationToken);
    }

    /// <summary>Get a schema version of a tenant event type</summary>
    public Task<JsonNode> GetWebhookEventTypeVersionAsync(
        string webhookEventTypeId,
        string version,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetWebhookEventTypeVersion, [webhookEventTypeId, version], query, null, options, cancellationToken);
    }

    /// <summary>List Relay's event catalog</summary>
    public Task<Page> ListWebhookCatalogAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListWebhookCatalog, [], query, null, options, cancellationToken);
    }

    /// <summary>List webhook endpoints</summary>
    public Task<Page> ListWebhookEndpointsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? use = null,
        string? state = null,
        string? consumerId = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("use", use);
        query.Add("state", state);
        query.Add("consumer_id", consumerId);
        return _client.ListAsync(Operations.ListWebhookEndpoints, [], query, null, options, cancellationToken);
    }

    /// <summary>Create a webhook endpoint</summary>
    public Task<JsonNode> CreateWebhookEndpointAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateWebhookEndpoint, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a webhook endpoint</summary>
    public Task<JsonNode> GetWebhookEndpointAsync(
        string webhookEndpointId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetWebhookEndpoint, [webhookEndpointId], query, null, options, cancellationToken);
    }

    /// <summary>Update a webhook endpoint</summary>
    public Task<JsonNode> UpdateWebhookEndpointAsync(
        string webhookEndpointId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.UpdateWebhookEndpoint, [webhookEndpointId], query, body, options, cancellationToken);
    }

    /// <summary>Archive a webhook endpoint</summary>
    public Task<JsonNode> ArchiveWebhookEndpointAsync(
        string webhookEndpointId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ArchiveWebhookEndpoint, [webhookEndpointId], query, null, options, cancellationToken);
    }

    /// <summary>Rotate a webhook endpoint's signing key</summary>
    public Task<JsonNode> RotateWebhookEndpointKeyAsync(
        string webhookEndpointId,
        JsonNode? body = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.RotateWebhookEndpointKey, [webhookEndpointId], query, body, options, cancellationToken);
    }

    /// <summary>List the versions of an endpoint</summary>
    public Task<Page> ListWebhookEndpointVersionsAsync(
        string webhookEndpointId,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListWebhookEndpointVersions, [webhookEndpointId], query, null, options, cancellationToken);
    }

    /// <summary>Get a version of an endpoint</summary>
    public Task<JsonNode> GetWebhookEndpointVersionAsync(
        string webhookEndpointId,
        string version,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetWebhookEndpointVersion, [webhookEndpointId, version], query, null, options, cancellationToken);
    }

    /// <summary>Pause a webhook endpoint</summary>
    public Task<JsonNode> PauseWebhookEndpointAsync(
        string webhookEndpointId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.PauseWebhookEndpoint, [webhookEndpointId], query, null, options, cancellationToken);
    }

    /// <summary>Resume a webhook endpoint</summary>
    public Task<JsonNode> ResumeWebhookEndpointAsync(
        string webhookEndpointId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ResumeWebhookEndpoint, [webhookEndpointId], query, null, options, cancellationToken);
    }

    /// <summary>Get the health of an endpoint</summary>
    public Task<JsonNode> GetWebhookEndpointHealthAsync(
        string webhookEndpointId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetWebhookEndpointHealth, [webhookEndpointId], query, null, options, cancellationToken);
    }

    /// <summary>Send a test event</summary>
    public Task<JsonNode> SendWebhookEndpointTestEventAsync(
        string webhookEndpointId,
        JsonNode? body = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.SendWebhookEndpointTestEvent, [webhookEndpointId], query, body, options, cancellationToken);
    }

    /// <summary>Recover an endpoint</summary>
    public Task<JsonNode> RecoverWebhookEndpointAsync(
        string webhookEndpointId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.RecoverWebhookEndpoint, [webhookEndpointId], query, body, options, cancellationToken);
    }

    /// <summary>Retry messages in bulk</summary>
    public Task<JsonNode> RetryWebhookEndpointMessagesAsync(
        string webhookEndpointId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.RetryWebhookEndpointMessages, [webhookEndpointId], query, body, options, cancellationToken);
    }

    /// <summary>Replay events to an endpoint</summary>
    public Task<JsonNode> ReplayWebhookEndpointEventsAsync(
        string webhookEndpointId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ReplayWebhookEndpointEvents, [webhookEndpointId], query, body, options, cancellationToken);
    }

    /// <summary>Cancel scheduled retries</summary>
    public Task<JsonNode> CancelWebhookEndpointRetriesAsync(
        string webhookEndpointId,
        JsonNode? body = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CancelWebhookEndpointRetries, [webhookEndpointId], query, body, options, cancellationToken);
    }

    /// <summary>List missed events</summary>
    public Task<Page> ListWebhookEndpointMissedEventsAsync(
        string webhookEndpointId,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? eventType = null,
        string? createdAfter = null,
        string? createdBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("event_type", eventType);
        query.Add("created_after", createdAfter);
        query.Add("created_before", createdBefore);
        return _client.ListAsync(Operations.ListWebhookEndpointMissedEvents, [webhookEndpointId], query, null, options, cancellationToken);
    }

    /// <summary>List webhook events</summary>
    public Task<Page> ListWebhookEventsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? eventType = null,
        string? createdAfter = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("event_type", eventType);
        query.Add("created_after", createdAfter);
        return _client.ListAsync(Operations.ListWebhookEvents, [], query, null, options, cancellationToken);
    }

    /// <summary>List webhook messages</summary>
    public Task<Page> ListWebhookMessagesAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? endpointId = null,
        string? eventId = null,
        string? state = null,
        string? eventType = null,
        string? createdAfter = null,
        string? createdBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("endpoint_id", endpointId);
        query.Add("event_id", eventId);
        query.Add("state", state);
        query.Add("event_type", eventType);
        query.Add("created_after", createdAfter);
        query.Add("created_before", createdBefore);
        return _client.ListAsync(Operations.ListWebhookMessages, [], query, null, options, cancellationToken);
    }

    /// <summary>Get a webhook message</summary>
    public Task<JsonNode> GetWebhookMessageAsync(
        string webhookMessageId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetWebhookMessage, [webhookMessageId], query, null, options, cancellationToken);
    }

    /// <summary>List the attempts of a message</summary>
    public Task<Page> ListWebhookMessageAttemptsAsync(
        string webhookMessageId,
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListWebhookMessageAttempts, [webhookMessageId], query, null, options, cancellationToken);
    }

    /// <summary>Get an attempt of a message</summary>
    public Task<JsonNode> GetWebhookMessageAttemptAsync(
        string webhookMessageId,
        string webhookAttemptId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetWebhookMessageAttempt, [webhookMessageId, webhookAttemptId], query, null, options, cancellationToken);
    }

    /// <summary>Resend a webhook message</summary>
    public Task<JsonNode> ResendWebhookMessageAsync(
        string webhookMessageId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ResendWebhookMessage, [webhookMessageId], query, null, options, cancellationToken);
    }

    /// <summary>Cancel a webhook message</summary>
    public Task<JsonNode> CancelWebhookMessageAsync(
        string webhookMessageId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CancelWebhookMessage, [webhookMessageId], query, null, options, cancellationToken);
    }

    /// <summary>Get the operations contacts</summary>
    public Task<JsonNode> GetOperationsContactsAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetOperationsContacts, [], query, null, options, cancellationToken);
    }

    /// <summary>Replace the operations contacts</summary>
    public Task<JsonNode> ReplaceOperationsContactsAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ReplaceOperationsContacts, [], query, body, options, cancellationToken);
    }

    /// <summary>Get the İYS configuration</summary>
    public Task<JsonNode> GetIysConfigAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetIysConfig, [], query, null, options, cancellationToken);
    }

    /// <summary>Replace the İYS configuration</summary>
    public Task<JsonNode> ReplaceIysConfigAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ReplaceIysConfig, [], query, body, options, cancellationToken);
    }

    /// <summary>List the İYS brands</summary>
    public Task<JsonNode> ListIysBrandsAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ListIysBrands, [], query, null, options, cancellationToken);
    }

    /// <summary>Test the İYS connection</summary>
    public Task<JsonNode> TestIysConnectionAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.TestIysConnection, [], query, null, options, cancellationToken);
    }

    /// <summary>List İYS uploads</summary>
    public Task<Page> ListIysUploadsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        string? state = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        query.Add("state", state);
        return _client.ListAsync(Operations.ListIysUploads, [], query, null, options, cancellationToken);
    }

    /// <summary>Put a subscriber's messaging conversation</summary>
    public Task<JsonNode> ReplaceSubscriberMessagingTargetAsync(
        string subscriberId,
        string channel,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ReplaceSubscriberMessagingTarget, [subscriberId, channel], query, body, options, cancellationToken);
    }

    /// <summary>Remove a subscriber's messaging conversation</summary>
    public Task<JsonNode> DeleteSubscriberMessagingTargetAsync(
        string subscriberId,
        string channel,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.DeleteSubscriberMessagingTarget, [subscriberId, channel], query, null, options, cancellationToken);
    }

    /// <summary>Install a messaging channel identity in a workspace</summary>
    public Task<JsonNode> CreateMessagingInstallationAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateMessagingInstallation, [], query, body, options, cancellationToken);
    }

    /// <summary>List channel adapters</summary>
    public Task<JsonNode> ListChannelAdaptersAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ListChannelAdapters, [], query, null, options, cancellationToken);
    }

    /// <summary>List WhatsApp templates</summary>
    public Task<Page> ListWhatsappTemplatesAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListWhatsappTemplates, [], query, null, options, cancellationToken);
    }

    /// <summary>Register a WhatsApp template</summary>
    public Task<JsonNode> RegisterWhatsappTemplateAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.RegisterWhatsappTemplate, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a WhatsApp template</summary>
    public Task<JsonNode> GetWhatsappTemplateAsync(
        string whatsappTemplateId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetWhatsappTemplate, [whatsappTemplateId], query, null, options, cancellationToken);
    }

    /// <summary>List provider accounts</summary>
    public Task<Page> ListProviderAccountsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListProviderAccounts, [], query, null, options, cancellationToken);
    }

    /// <summary>Get a provider account</summary>
    public Task<JsonNode> GetProviderAccountAsync(
        string providerAccountId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetProviderAccount, [providerAccountId], query, null, options, cancellationToken);
    }

    /// <summary>Update a provider account</summary>
    public Task<JsonNode> UpdateProviderAccountAsync(
        string providerAccountId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.UpdateProviderAccount, [providerAccountId], query, body, options, cancellationToken);
    }

    /// <summary>Verify a provider account</summary>
    public Task<JsonNode> VerifyProviderAccountAsync(
        string providerAccountId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.VerifyProviderAccount, [providerAccountId], query, null, options, cancellationToken);
    }

    /// <summary>Get the status of a provider account</summary>
    public Task<JsonNode> GetProviderAccountStatusAsync(
        string providerAccountId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetProviderAccountStatus, [providerAccountId], query, null, options, cancellationToken);
    }

    /// <summary>Check the sending domains of an e-mail provider account</summary>
    public Task<JsonNode> GetProviderAccountEmailDomainsAsync(
        string providerAccountId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetProviderAccountEmailDomains, [providerAccountId], query, null, options, cancellationToken);
    }

    /// <summary>List the e-mail warm-up plans</summary>
    public Task<JsonNode> ListEmailWarmupPlansAsync(
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ListEmailWarmupPlans, [], query, null, options, cancellationToken);
    }

    /// <summary>Quote the cost of a paid channel</summary>
    public Task<JsonNode> QuoteChannelCostAsync(
        string channel,
        string country,
        string? category = null,
        int? quantity = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("channel", channel);
        query.Add("country", country);
        query.Add("category", category);
        query.Add("quantity", quantity);
        return _client.SendJsonAsync(Operations.QuoteChannelCost, [], query, null, options, cancellationToken);
    }

    /// <summary>List provider invoices</summary>
    public Task<Page> ListProviderInvoicesAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListProviderInvoices, [], query, null, options, cancellationToken);
    }

    /// <summary>Record a provider invoice</summary>
    public Task<JsonNode> CreateProviderInvoiceAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateProviderInvoice, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a provider invoice</summary>
    public Task<JsonNode> GetProviderInvoiceAsync(
        string providerInvoiceId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetProviderInvoice, [providerInvoiceId], query, null, options, cancellationToken);
    }

    /// <summary>List raw data exports</summary>
    public Task<Page> ListExportsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListExports, [], query, null, options, cancellationToken);
    }

    /// <summary>Request a raw data export</summary>
    public Task<JsonNode> CreateExportAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateExport, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a raw data export</summary>
    public Task<JsonNode> GetExportAsync(
        string exportId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetExport, [exportId], query, null, options, cancellationToken);
    }

    /// <summary>List campaigns</summary>
    public Task<Page> ListCampaignsAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListCampaigns, [], query, null, options, cancellationToken);
    }

    /// <summary>Create a campaign</summary>
    public Task<JsonNode> CreateCampaignAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateCampaign, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a campaign</summary>
    public Task<JsonNode> GetCampaignAsync(
        string campaignId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetCampaign, [campaignId], query, null, options, cancellationToken);
    }

    /// <summary>Add recipients to a campaign</summary>
    public Task<JsonNode> AddCampaignRecipientsAsync(
        string campaignId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.AddCampaignRecipients, [campaignId], query, body, options, cancellationToken);
    }

    /// <summary>Prepare a campaign</summary>
    public Task<JsonNode> PrepareCampaignAsync(
        string campaignId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.PrepareCampaign, [campaignId], query, null, options, cancellationToken);
    }

    /// <summary>Render the samples of a campaign</summary>
    public Task<JsonNode> GetCampaignSamplesAsync(
        string campaignId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetCampaignSamples, [campaignId], query, null, options, cancellationToken);
    }

    /// <summary>Approve the samples of a campaign</summary>
    public Task<JsonNode> ApproveCampaignSamplesAsync(
        string campaignId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ApproveCampaignSamples, [campaignId], query, body, options, cancellationToken);
    }

    /// <summary>Trigger a campaign</summary>
    public Task<JsonNode> TriggerCampaignAsync(
        string campaignId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.TriggerCampaign, [campaignId], query, null, options, cancellationToken);
    }

    /// <summary>Cancel a campaign</summary>
    public Task<JsonNode> CancelCampaignAsync(
        string campaignId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CancelCampaign, [campaignId], query, body, options, cancellationToken);
    }

    /// <summary>Get the delivery report</summary>
    public Task<JsonNode> GetDeliveryReportAsync(
        string @from,
        string to,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("from", @from);
        query.Add("to", to);
        return _client.SendJsonAsync(Operations.GetDeliveryReport, [], query, null, options, cancellationToken);
    }

    /// <summary>Get the skip distribution</summary>
    public Task<JsonNode> GetSkipReportAsync(
        string @from,
        string to,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("from", @from);
        query.Add("to", to);
        return _client.SendJsonAsync(Operations.GetSkipReport, [], query, null, options, cancellationToken);
    }

    /// <summary>Get the cost report</summary>
    public Task<JsonNode> GetCostReportAsync(
        string @from,
        string to,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("from", @from);
        query.Add("to", to);
        return _client.SendJsonAsync(Operations.GetCostReport, [], query, null, options, cancellationToken);
    }

    /// <summary>List sender identities</summary>
    public Task<Page> ListSenderIdentitiesAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListSenderIdentities, [], query, null, options, cancellationToken);
    }

    /// <summary>Create a sender identity</summary>
    public Task<JsonNode> CreateSenderIdentityAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateSenderIdentity, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a sender identity</summary>
    public Task<JsonNode> GetSenderIdentityAsync(
        string senderIdentityId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetSenderIdentity, [senderIdentityId], query, null, options, cancellationToken);
    }

    /// <summary>Update a sender identity</summary>
    public Task<JsonNode> UpdateSenderIdentityAsync(
        string senderIdentityId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.UpdateSenderIdentity, [senderIdentityId], query, body, options, cancellationToken);
    }

    /// <summary>Archive a sender identity</summary>
    public Task<JsonNode> ArchiveSenderIdentityAsync(
        string senderIdentityId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ArchiveSenderIdentity, [senderIdentityId], query, null, options, cancellationToken);
    }

    /// <summary>List channel identities</summary>
    public Task<Page> ListChannelIdentitiesAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListChannelIdentities, [], query, null, options, cancellationToken);
    }

    /// <summary>Get a channel identity</summary>
    public Task<JsonNode> GetChannelIdentityAsync(
        string channelIdentityId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetChannelIdentity, [channelIdentityId], query, null, options, cancellationToken);
    }

    /// <summary>Update a channel identity</summary>
    public Task<JsonNode> UpdateChannelIdentityAsync(
        string channelIdentityId,
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.UpdateChannelIdentity, [channelIdentityId], query, body, options, cancellationToken);
    }

    /// <summary>Retire a channel identity</summary>
    public Task<JsonNode> ArchiveChannelIdentityAsync(
        string channelIdentityId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ArchiveChannelIdentity, [channelIdentityId], query, null, options, cancellationToken);
    }

    /// <summary>Upload a DMARC aggregate or TLS report</summary>
    public Task<JsonNode> UploadEmailReportAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.UploadEmailReport, [], query, body, options, cancellationToken);
    }

    /// <summary>Summarize a domain's DMARC and TLS reports</summary>
    public Task<JsonNode> GetEmailReportSummaryAsync(
        string domain,
        string? @from = null,
        string? to = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("domain", domain);
        query.Add("from", @from);
        query.Add("to", to);
        return _client.SendJsonAsync(Operations.GetEmailReportSummary, [], query, null, options, cancellationToken);
    }

    /// <summary>List recurrence rules</summary>
    public Task<Page> ListRecurrencesAsync(
        int? limit = null,
        string? startingAfter = null,
        string? endingBefore = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        query.Add("limit", limit);
        query.Add("starting_after", startingAfter);
        query.Add("ending_before", endingBefore);
        return _client.ListAsync(Operations.ListRecurrences, [], query, null, options, cancellationToken);
    }

    /// <summary>Define a recurrence rule</summary>
    public Task<JsonNode> CreateRecurrenceAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CreateRecurrence, [], query, body, options, cancellationToken);
    }

    /// <summary>Get a recurrence rule</summary>
    public Task<JsonNode> GetRecurrenceAsync(
        string recurrenceId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.GetRecurrence, [recurrenceId], query, null, options, cancellationToken);
    }

    /// <summary>Cancel a recurrence rule</summary>
    public Task<JsonNode> CancelRecurrenceAsync(
        string recurrenceId,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.CancelRecurrence, [recurrenceId], query, null, options, cancellationToken);
    }

    /// <summary>Reset an active throttle</summary>
    public Task<JsonNode> ResetThrottleAsync(
        string throttleKey,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var query = new QueryBuilder();
        return _client.SendJsonAsync(Operations.ResetThrottle, [throttleKey], query, null, options, cancellationToken);
    }
}
