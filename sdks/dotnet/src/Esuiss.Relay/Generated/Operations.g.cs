#nullable enable

namespace Esuiss.Relay;

/// <summary>Every operation of the Relay server API that an API client calls.</summary>
public static partial class Operations
{
    /// <summary>Send an event</summary>
    public static readonly Operation CreateEvent = new("createEvent", "POST", "/v1/events", IdempotencyMode.Optional, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Send a batch of events</summary>
    public static readonly Operation CreateEventBatch = new("createEventBatch", "POST", "/v1/events/batch", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get an event</summary>
    public static readonly Operation GetEvent = new("getEvent", "GET", "/v1/events/{event_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Cancel an event</summary>
    public static readonly Operation CancelEvent = new("cancelEvent", "POST", "/v1/events/{event_id}/cancel", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Optional, "application/json", ResponseKind.Json);

    /// <summary>Cancel by cancellation key</summary>
    public static readonly Operation CancelEventsByKey = new("cancelEventsByKey", "POST", "/v1/events/cancel_by_key", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List notifications</summary>
    public static readonly Operation ListNotifications = new("listNotifications", "GET", "/v1/notifications", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get a notification</summary>
    public static readonly Operation GetNotification = new("getNotification", "GET", "/v1/notifications/{notification_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Cancel a notification</summary>
    public static readonly Operation CancelNotification = new("cancelNotification", "POST", "/v1/notifications/{notification_id}/cancel", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Optional, "application/json", ResponseKind.Json);

    /// <summary>List deliveries of a notification</summary>
    public static readonly Operation ListNotificationDeliveries = new("listNotificationDeliveries", "GET", "/v1/notifications/{notification_id}/deliveries", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get attempt history and ledger of a delivery</summary>
    public static readonly Operation GetDeliveryHistory = new("getDeliveryHistory", "GET", "/v1/deliveries/{delivery_id}/history", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Explain why a subscriber did or did not get notifications</summary>
    public static readonly Operation ListSubscriberDecisions = new("listSubscriberDecisions", "GET", "/v1/subscribers/{subscriber_id}/decisions", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create a subscriber</summary>
    public static readonly Operation CreateSubscriber = new("createSubscriber", "POST", "/v1/subscribers", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List subscribers</summary>
    public static readonly Operation ListSubscribers = new("listSubscribers", "GET", "/v1/subscribers", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get a subscriber</summary>
    public static readonly Operation GetSubscriber = new("getSubscriber", "GET", "/v1/subscribers/{subscriber_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create or replace a subscriber</summary>
    public static readonly Operation ReplaceSubscriber = new("replaceSubscriber", "PUT", "/v1/subscribers/{subscriber_id}", IdempotencyMode.Required, IfMatchMode.Optional, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Update a subscriber</summary>
    public static readonly Operation UpdateSubscriber = new("updateSubscriber", "PATCH", "/v1/subscribers/{subscriber_id}", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Required, "application/merge-patch+json", ResponseKind.Json);

    /// <summary>Request deletion of a subscriber</summary>
    public static readonly Operation DeleteSubscriber = new("deleteSubscriber", "DELETE", "/v1/subscribers/{subscriber_id}", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Bulk upsert subscribers</summary>
    public static readonly Operation BulkUpsertSubscribers = new("bulkUpsertSubscribers", "POST", "/v1/subscribers/bulk", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get subscriber preferences</summary>
    public static readonly Operation GetSubscriberPreferences = new("getSubscriberPreferences", "GET", "/v1/subscribers/{subscriber_id}/preferences", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Update subscriber preferences</summary>
    public static readonly Operation UpdateSubscriberPreferences = new("updateSubscriberPreferences", "PATCH", "/v1/subscribers/{subscriber_id}/preferences", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Mint a hosted preference page link</summary>
    public static readonly Operation CreatePreferencePageLink = new("createPreferencePageLink", "POST", "/v1/subscribers/{subscriber_id}/preference_page_links", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List subscriber consents</summary>
    public static readonly Operation ListSubscriberConsents = new("listSubscriberConsents", "GET", "/v1/subscribers/{subscriber_id}/consents", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List subscriber devices</summary>
    public static readonly Operation ListSubscriberDevices = new("listSubscriberDevices", "GET", "/v1/subscribers/{subscriber_id}/devices", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Register a subscriber device</summary>
    public static readonly Operation RegisterSubscriberDevice = new("registerSubscriberDevice", "POST", "/v1/subscribers/{subscriber_id}/devices", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Remove a subscriber device</summary>
    public static readonly Operation DeleteSubscriberDevice = new("deleteSubscriberDevice", "DELETE", "/v1/subscribers/{subscriber_id}/devices/{device_id}", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Remove a device by its token</summary>
    public static readonly Operation DeleteDeviceByToken = new("deleteDeviceByToken", "DELETE", "/v1/devices/by-token", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get the jitter control</summary>
    public static readonly Operation GetTimingSettings = new("getTimingSettings", "GET", "/v1/timing_settings", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Set the jitter control</summary>
    public static readonly Operation SetTimingSettings = new("setTimingSettings", "PUT", "/v1/timing_settings", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get the allowed browser origins</summary>
    public static readonly Operation GetRealtimeOrigins = new("getRealtimeOrigins", "GET", "/v1/realtime_origins", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Set the allowed browser origins</summary>
    public static readonly Operation SetRealtimeOrigins = new("setRealtimeOrigins", "PUT", "/v1/realtime_origins", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List routes</summary>
    public static readonly Operation ListRoutes = new("listRoutes", "GET", "/v1/routes", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create a route</summary>
    public static readonly Operation CreateRoute = new("createRoute", "POST", "/v1/routes", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a route</summary>
    public static readonly Operation GetRoute = new("getRoute", "GET", "/v1/routes/{route_key}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Replace a route</summary>
    public static readonly Operation ReplaceRoute = new("replaceRoute", "PUT", "/v1/routes/{route_key}", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Archive a route</summary>
    public static readonly Operation ArchiveRoute = new("archiveRoute", "POST", "/v1/routes/{route_key}/archive", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List workflows</summary>
    public static readonly Operation ListWorkflows = new("listWorkflows", "GET", "/v1/workflows", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create a workflow</summary>
    public static readonly Operation CreateWorkflow = new("createWorkflow", "POST", "/v1/workflows", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a workflow</summary>
    public static readonly Operation GetWorkflow = new("getWorkflow", "GET", "/v1/workflows/{workflow_key}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Replace the workflow draft</summary>
    public static readonly Operation ReplaceWorkflowDraft = new("replaceWorkflowDraft", "PUT", "/v1/workflows/{workflow_key}", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Publish the draft</summary>
    public static readonly Operation PublishWorkflow = new("publishWorkflow", "POST", "/v1/workflows/{workflow_key}/publish", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Optional, "application/json", ResponseKind.Json);

    /// <summary>Change the workflow manager</summary>
    public static readonly Operation SetWorkflowManager = new("setWorkflowManager", "POST", "/v1/workflows/{workflow_key}/manager", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List published versions</summary>
    public static readonly Operation ListWorkflowVersions = new("listWorkflowVersions", "GET", "/v1/workflows/{workflow_key}/versions", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get a published version</summary>
    public static readonly Operation GetWorkflowVersion = new("getWorkflowVersion", "GET", "/v1/workflows/{workflow_key}/versions/{version}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Export a published version as Mermaid</summary>
    public static readonly Operation GetWorkflowVersionMermaid = new("getWorkflowVersionMermaid", "GET", "/v1/workflows/{workflow_key}/versions/{version}/mermaid", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Text);

    /// <summary>Republish an earlier version</summary>
    public static readonly Operation PromoteWorkflowVersion = new("promoteWorkflowVersion", "POST", "/v1/workflows/{workflow_key}/versions/{version}/promote", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Preview a workflow</summary>
    public static readonly Operation PreviewWorkflow = new("previewWorkflow", "POST", "/v1/workflows/{workflow_key}/preview", IdempotencyMode.None, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Test send a workflow</summary>
    public static readonly Operation SendWorkflowTest = new("sendWorkflowTest", "POST", "/v1/workflows/{workflow_key}/test", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List templates</summary>
    public static readonly Operation ListTemplates = new("listTemplates", "GET", "/v1/templates", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create a template</summary>
    public static readonly Operation CreateTemplate = new("createTemplate", "POST", "/v1/templates", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a template</summary>
    public static readonly Operation GetTemplate = new("getTemplate", "GET", "/v1/templates/{template_key}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Replace the template draft</summary>
    public static readonly Operation ReplaceTemplateDraft = new("replaceTemplateDraft", "PUT", "/v1/templates/{template_key}", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Publish the draft</summary>
    public static readonly Operation PublishTemplate = new("publishTemplate", "POST", "/v1/templates/{template_key}/publish", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Optional, "application/json", ResponseKind.Json);

    /// <summary>Archive the template</summary>
    public static readonly Operation ArchiveTemplate = new("archiveTemplate", "POST", "/v1/templates/{template_key}/archive", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List template versions</summary>
    public static readonly Operation ListTemplateVersions = new("listTemplateVersions", "GET", "/v1/templates/{template_key}/versions", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get a template version</summary>
    public static readonly Operation GetTemplateVersion = new("getTemplateVersion", "GET", "/v1/templates/{template_key}/versions/{version}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Roll back to a version</summary>
    public static readonly Operation PromoteTemplateVersion = new("promoteTemplateVersion", "POST", "/v1/templates/{template_key}/versions/{version}/promote", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get the translation matrix</summary>
    public static readonly Operation GetTemplateTranslations = new("getTemplateTranslations", "GET", "/v1/templates/{template_key}/translations", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Preview a template</summary>
    public static readonly Operation PreviewTemplate = new("previewTemplate", "POST", "/v1/templates/{template_key}/preview", IdempotencyMode.None, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Publish a producer template</summary>
    public static readonly Operation PublishProducerTemplate = new("publishProducerTemplate", "PUT", "/v1/producer_templates/{template_key}", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List layouts</summary>
    public static readonly Operation ListLayouts = new("listLayouts", "GET", "/v1/layouts", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create a layout</summary>
    public static readonly Operation CreateLayout = new("createLayout", "POST", "/v1/layouts", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a layout</summary>
    public static readonly Operation GetLayout = new("getLayout", "GET", "/v1/layouts/{layout_key}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Replace the layout draft</summary>
    public static readonly Operation ReplaceLayoutDraft = new("replaceLayoutDraft", "PUT", "/v1/layouts/{layout_key}", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Publish the draft</summary>
    public static readonly Operation PublishLayout = new("publishLayout", "POST", "/v1/layouts/{layout_key}/publish", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Optional, "application/json", ResponseKind.Json);

    /// <summary>Archive the layout</summary>
    public static readonly Operation ArchiveLayout = new("archiveLayout", "POST", "/v1/layouts/{layout_key}/archive", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List layout versions</summary>
    public static readonly Operation ListLayoutVersions = new("listLayoutVersions", "GET", "/v1/layouts/{layout_key}/versions", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get a layout version</summary>
    public static readonly Operation GetLayoutVersion = new("getLayoutVersion", "GET", "/v1/layouts/{layout_key}/versions/{version}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Roll back to a version</summary>
    public static readonly Operation PromoteLayoutVersion = new("promoteLayoutVersion", "POST", "/v1/layouts/{layout_key}/versions/{version}/promote", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List partials</summary>
    public static readonly Operation ListPartials = new("listPartials", "GET", "/v1/partials", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create a partial</summary>
    public static readonly Operation CreatePartial = new("createPartial", "POST", "/v1/partials", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a partial</summary>
    public static readonly Operation GetPartial = new("getPartial", "GET", "/v1/partials/{partial_key}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Replace the partial draft</summary>
    public static readonly Operation ReplacePartialDraft = new("replacePartialDraft", "PUT", "/v1/partials/{partial_key}", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Publish the draft</summary>
    public static readonly Operation PublishPartial = new("publishPartial", "POST", "/v1/partials/{partial_key}/publish", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Optional, "application/json", ResponseKind.Json);

    /// <summary>Archive the partial</summary>
    public static readonly Operation ArchivePartial = new("archivePartial", "POST", "/v1/partials/{partial_key}/archive", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List partial versions</summary>
    public static readonly Operation ListPartialVersions = new("listPartialVersions", "GET", "/v1/partials/{partial_key}/versions", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get a partial version</summary>
    public static readonly Operation GetPartialVersion = new("getPartialVersion", "GET", "/v1/partials/{partial_key}/versions/{version}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Roll back to a version</summary>
    public static readonly Operation PromotePartialVersion = new("promotePartialVersion", "POST", "/v1/partials/{partial_key}/versions/{version}/promote", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get the brand settings</summary>
    public static readonly Operation GetBrand = new("getBrand", "GET", "/v1/brand", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Update the brand settings</summary>
    public static readonly Operation UpdateBrand = new("updateBrand", "PATCH", "/v1/brand", IdempotencyMode.Required, IfMatchMode.Optional, BodyMode.Required, "application/merge-patch+json", ResponseKind.Json);

    /// <summary>Get the compliance settings</summary>
    public static readonly Operation GetComplianceSettings = new("getComplianceSettings", "GET", "/v1/compliance_settings", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Replace the tenant compliance settings</summary>
    public static readonly Operation ReplaceComplianceSettings = new("replaceComplianceSettings", "PUT", "/v1/compliance_settings", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get the DLR windows</summary>
    public static readonly Operation GetDeliveryWindows = new("getDeliveryWindows", "GET", "/v1/delivery_windows", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Replace the tenant DLR windows</summary>
    public static readonly Operation ReplaceDeliveryWindows = new("replaceDeliveryWindows", "PUT", "/v1/delivery_windows", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List CloudEvents type mappings</summary>
    public static readonly Operation ListEventTypeMappings = new("listEventTypeMappings", "GET", "/v1/event_type_mappings", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create a CloudEvents type mapping</summary>
    public static readonly Operation CreateEventTypeMapping = new("createEventTypeMapping", "POST", "/v1/event_type_mappings", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a CloudEvents type mapping</summary>
    public static readonly Operation GetEventTypeMapping = new("getEventTypeMapping", "GET", "/v1/event_type_mappings/{mapping_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Replace a CloudEvents type mapping</summary>
    public static readonly Operation ReplaceEventTypeMapping = new("replaceEventTypeMapping", "PUT", "/v1/event_type_mappings/{mapping_id}", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Archive a CloudEvents type mapping</summary>
    public static readonly Operation ArchiveEventTypeMapping = new("archiveEventTypeMapping", "POST", "/v1/event_type_mappings/{mapping_id}/archive", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List categories</summary>
    public static readonly Operation ListCategories = new("listCategories", "GET", "/v1/categories", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create a category</summary>
    public static readonly Operation CreateCategory = new("createCategory", "POST", "/v1/categories", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a category</summary>
    public static readonly Operation GetCategory = new("getCategory", "GET", "/v1/categories/{category_key}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Update a category</summary>
    public static readonly Operation UpdateCategory = new("updateCategory", "PATCH", "/v1/categories/{category_key}", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Required, "application/merge-patch+json", ResponseKind.Json);

    /// <summary>Archive a category</summary>
    public static readonly Operation ArchiveCategory = new("archiveCategory", "POST", "/v1/categories/{category_key}/archive", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List sub-tenants</summary>
    public static readonly Operation ListSubtenants = new("listSubtenants", "GET", "/v1/subtenants", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get a subtenant setting of a category</summary>
    public static readonly Operation GetCategorySubtenantSetting = new("getCategorySubtenantSetting", "GET", "/v1/categories/{category_key}/subtenants/{subtenant_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Set a subtenant setting of a category</summary>
    public static readonly Operation ReplaceCategorySubtenantSetting = new("replaceCategorySubtenantSetting", "PUT", "/v1/categories/{category_key}/subtenants/{subtenant_id}", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get the e-mail tracking of a category</summary>
    public static readonly Operation GetCategoryEmailTracking = new("getCategoryEmailTracking", "GET", "/v1/categories/{category_key}/email_tracking", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Set the e-mail tracking of a category</summary>
    public static readonly Operation ReplaceCategoryEmailTracking = new("replaceCategoryEmailTracking", "PUT", "/v1/categories/{category_key}/email_tracking", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get the e-mail tracking of a template</summary>
    public static readonly Operation GetTemplateEmailTracking = new("getTemplateEmailTracking", "GET", "/v1/templates/{template_key}/email_tracking", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Set the e-mail tracking of a template</summary>
    public static readonly Operation ReplaceTemplateEmailTracking = new("replaceTemplateEmailTracking", "PUT", "/v1/templates/{template_key}/email_tracking", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List suppressions</summary>
    public static readonly Operation ListSuppressions = new("listSuppressions", "GET", "/v1/suppressions", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Add a suppression</summary>
    public static readonly Operation CreateSuppression = new("createSuppression", "POST", "/v1/suppressions", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Lift a suppression</summary>
    public static readonly Operation LiftSuppression = new("liftSuppression", "POST", "/v1/suppressions/{suppression_id}/lift", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get the SMS destination policy</summary>
    public static readonly Operation GetSmsDestinationPolicy = new("getSmsDestinationPolicy", "GET", "/v1/sms_destination_policy", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Set the SMS destination policy</summary>
    public static readonly Operation SetSmsDestinationPolicy = new("setSmsDestinationPolicy", "PUT", "/v1/sms_destination_policy", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List SMS destination stops</summary>
    public static readonly Operation ListSmsDestinationStops = new("listSmsDestinationStops", "GET", "/v1/sms_destination_stops", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Lift an SMS destination stop</summary>
    public static readonly Operation LiftSmsDestinationStop = new("liftSmsDestinationStop", "POST", "/v1/sms_destination_stops/{sms_destination_stop_id}/lift", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List test recipients</summary>
    public static readonly Operation ListTestRecipients = new("listTestRecipients", "GET", "/v1/test_recipients", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Add a test recipient</summary>
    public static readonly Operation CreateTestRecipient = new("createTestRecipient", "POST", "/v1/test_recipients", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Remove a test recipient</summary>
    public static readonly Operation RemoveTestRecipient = new("removeTestRecipient", "POST", "/v1/test_recipients/{test_recipient_id}/remove", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Publish an inbox announcement</summary>
    public static readonly Operation CreateInboxAnnouncement = new("createInboxAnnouncement", "POST", "/v1/inbox/announcements", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get an inbox announcement</summary>
    public static readonly Operation GetInboxAnnouncement = new("getInboxAnnouncement", "GET", "/v1/inbox/announcements/{announcement_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Retract an inbox announcement</summary>
    public static readonly Operation RetractInboxAnnouncement = new("retractInboxAnnouncement", "POST", "/v1/inbox/announcements/{announcement_id}/retract", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List topics</summary>
    public static readonly Operation ListTopics = new("listTopics", "GET", "/v1/topics", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create a topic</summary>
    public static readonly Operation CreateTopic = new("createTopic", "POST", "/v1/topics", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a topic</summary>
    public static readonly Operation GetTopic = new("getTopic", "GET", "/v1/topics/{topic_key}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Archive a topic</summary>
    public static readonly Operation ArchiveTopic = new("archiveTopic", "POST", "/v1/topics/{topic_key}/archive", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List the subscriptions of a topic</summary>
    public static readonly Operation ListTopicSubscriptions = new("listTopicSubscriptions", "GET", "/v1/topics/{topic_key}/subscriptions", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Subscribe subscribers to a topic</summary>
    public static readonly Operation AddTopicSubscriptions = new("addTopicSubscriptions", "POST", "/v1/topics/{topic_key}/subscriptions", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Unsubscribe subscribers from a topic</summary>
    public static readonly Operation RemoveTopicSubscriptions = new("removeTopicSubscriptions", "POST", "/v1/topics/{topic_key}/subscriptions/remove", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List the topics a subscriber is subscribed to</summary>
    public static readonly Operation ListSubscriberSubscriptions = new("listSubscriberSubscriptions", "GET", "/v1/subscribers/{subscriber_id}/subscriptions", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List kill switches</summary>
    public static readonly Operation ListKillSwitches = new("listKillSwitches", "GET", "/v1/kill_switches", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Engage a kill switch</summary>
    public static readonly Operation EngageKillSwitch = new("engageKillSwitch", "POST", "/v1/kill_switches", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a kill switch</summary>
    public static readonly Operation GetKillSwitch = new("getKillSwitch", "GET", "/v1/kill_switches/{kill_switch_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Replace the state of a kill switch</summary>
    public static readonly Operation ReplaceKillSwitch = new("replaceKillSwitch", "POST", "/v1/kill_switches/{kill_switch_id}/replace", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get the virtual clock</summary>
    public static readonly Operation GetVirtualClock = new("getVirtualClock", "GET", "/v1/virtual_clock", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Advance the virtual clock</summary>
    public static readonly Operation AdvanceVirtualClock = new("advanceVirtualClock", "POST", "/v1/virtual_clock/advance", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List the simulated results of the fake provider</summary>
    public static readonly Operation ListSimulatedResults = new("listSimulatedResults", "GET", "/v1/test/simulated-results", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List the seed recipients of the test plane</summary>
    public static readonly Operation ListSeedRecipients = new("listSeedRecipients", "GET", "/v1/test/seed-recipients", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Reset the seed recipients of the test plane</summary>
    public static readonly Operation ResetSeedRecipients = new("resetSeedRecipients", "POST", "/v1/test/seed-recipients/reset", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List the test inbox</summary>
    public static readonly Operation ListTestInboxMessages = new("listTestInboxMessages", "GET", "/v1/test/inbox", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List waitpoints</summary>
    public static readonly Operation ListWaitpoints = new("listWaitpoints", "GET", "/v1/waitpoints", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create a waitpoint</summary>
    public static readonly Operation CreateWaitpoint = new("createWaitpoint", "POST", "/v1/waitpoints", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a waitpoint</summary>
    public static readonly Operation GetWaitpoint = new("getWaitpoint", "GET", "/v1/waitpoints/{waitpoint_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Cancel a waitpoint</summary>
    public static readonly Operation CancelWaitpoint = new("cancelWaitpoint", "POST", "/v1/waitpoints/{waitpoint_id}/cancel", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Send a waiter heartbeat</summary>
    public static readonly Operation HeartbeatWaitpoint = new("heartbeatWaitpoint", "POST", "/v1/waitpoints/{waitpoint_id}/heartbeat", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get the caller's mailbox</summary>
    public static readonly Operation GetMailbox = new("getMailbox", "GET", "/v1/mailbox", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Lease mailbox records</summary>
    public static readonly Operation LeaseMailboxRecords = new("leaseMailboxRecords", "POST", "/v1/mailbox/leases", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Optional, "application/json", ResponseKind.Json);

    /// <summary>Acknowledge mailbox records</summary>
    public static readonly Operation AckMailboxRecords = new("ackMailboxRecords", "POST", "/v1/mailbox/acks", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Publish an AG-UI event</summary>
    public static readonly Operation PublishAgUiEvent = new("publishAgUiEvent", "POST", "/v1/agui/events", IdempotencyMode.None, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Call the MCP server</summary>
    public static readonly Operation CallMcp = new("callMcp", "POST", "/v1/mcp", IdempotencyMode.None, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Read mailbox records in order</summary>
    public static readonly Operation ListMailboxRecords = new("listMailboxRecords", "GET", "/v1/mailbox/records", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get a mailbox record by its handle</summary>
    public static readonly Operation GetMailboxRecord = new("getMailboxRecord", "GET", "/v1/mailbox/records/{record_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List dead-lettered mailbox records</summary>
    public static readonly Operation ListMailboxDeadLetters = new("listMailboxDeadLetters", "GET", "/v1/mailbox/dead_letters", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Send a message to an agent's mailbox</summary>
    public static readonly Operation SendMailboxMessage = new("sendMailboxMessage", "POST", "/v1/mailbox/messages", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List the request box</summary>
    public static readonly Operation ListMailboxRequests = new("listMailboxRequests", "GET", "/v1/mailbox/requests", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Read the encrypted envelope of a message</summary>
    public static readonly Operation GetMailboxEnvelope = new("getMailboxEnvelope", "GET", "/v1/mailbox/envelopes", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Block or unblock a sender</summary>
    public static readonly Operation SetMailboxSenderBlock = new("setMailboxSenderBlock", "POST", "/v1/mailbox/blocks", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Report a mailbox message as abuse</summary>
    public static readonly Operation ReportMailboxAbuse = new("reportMailboxAbuse", "POST", "/v1/mailbox/abuse_reports", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List escalation policies</summary>
    public static readonly Operation ListEscalationPolicies = new("listEscalationPolicies", "GET", "/v1/escalation_policies", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get an escalation policy</summary>
    public static readonly Operation GetEscalationPolicy = new("getEscalationPolicy", "GET", "/v1/escalation_policies/{policy_key}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Write an escalation policy version</summary>
    public static readonly Operation PutEscalationPolicy = new("putEscalationPolicy", "PUT", "/v1/escalation_policies/{policy_key}", IdempotencyMode.Required, IfMatchMode.Optional, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List escalation policy versions</summary>
    public static readonly Operation ListEscalationPolicyVersions = new("listEscalationPolicyVersions", "GET", "/v1/escalation_policies/{policy_key}/versions", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Archive an escalation policy</summary>
    public static readonly Operation ArchiveEscalationPolicy = new("archiveEscalationPolicy", "POST", "/v1/escalation_policies/{policy_key}/archive", IdempotencyMode.Required, IfMatchMode.Optional, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List agents</summary>
    public static readonly Operation ListAgents = new("listAgents", "GET", "/v1/agents", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create an agent</summary>
    public static readonly Operation CreateAgent = new("createAgent", "POST", "/v1/agents", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get an agent</summary>
    public static readonly Operation GetAgent = new("getAgent", "GET", "/v1/agents/{agent_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Update an agent</summary>
    public static readonly Operation UpdateAgent = new("updateAgent", "PATCH", "/v1/agents/{agent_id}", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Required, "application/merge-patch+json", ResponseKind.Json);

    /// <summary>Delete an agent</summary>
    public static readonly Operation DeleteAgent = new("deleteAgent", "DELETE", "/v1/agents/{agent_id}", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Decide on held agent notifications</summary>
    public static readonly Operation CreateAgentCeilingDecision = new("createAgentCeilingDecision", "POST", "/v1/agents/{agent_id}/ceiling_decisions", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List held agent notifications</summary>
    public static readonly Operation ListAgentCeilingHolds = new("listAgentCeilingHolds", "GET", "/v1/agents/{agent_id}/ceiling_holds", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Resume a stopped agent</summary>
    public static readonly Operation ResumeAgent = new("resumeAgent", "POST", "/v1/agents/{agent_id}/resume", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List webhook consumers</summary>
    public static readonly Operation ListWebhookConsumers = new("listWebhookConsumers", "GET", "/v1/webhook_consumers", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create a webhook consumer</summary>
    public static readonly Operation CreateWebhookConsumer = new("createWebhookConsumer", "POST", "/v1/webhook_consumers", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a webhook consumer</summary>
    public static readonly Operation GetWebhookConsumer = new("getWebhookConsumer", "GET", "/v1/webhook_consumers/{webhook_consumer_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Update a webhook consumer</summary>
    public static readonly Operation UpdateWebhookConsumer = new("updateWebhookConsumer", "PATCH", "/v1/webhook_consumers/{webhook_consumer_id}", IdempotencyMode.Required, IfMatchMode.Optional, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Archive a webhook consumer</summary>
    public static readonly Operation ArchiveWebhookConsumer = new("archiveWebhookConsumer", "POST", "/v1/webhook_consumers/{webhook_consumer_id}/archive", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List completion sources</summary>
    public static readonly Operation ListWebhookSources = new("listWebhookSources", "GET", "/v1/webhook_sources", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Register a completion source</summary>
    public static readonly Operation CreateWebhookSource = new("createWebhookSource", "POST", "/v1/webhook_sources", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a completion source</summary>
    public static readonly Operation GetWebhookSource = new("getWebhookSource", "GET", "/v1/webhook_sources/{webhook_source_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Archive a completion source</summary>
    public static readonly Operation ArchiveWebhookSource = new("archiveWebhookSource", "POST", "/v1/webhook_sources/{webhook_source_id}/archive", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Mint a webhook portal token</summary>
    public static readonly Operation CreateWebhookPortalToken = new("createWebhookPortalToken", "POST", "/v1/webhook_consumers/{webhook_consumer_id}/portal_tokens", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List tenant event types</summary>
    public static readonly Operation ListWebhookEventTypes = new("listWebhookEventTypes", "GET", "/v1/webhook_event_types", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create a tenant event type</summary>
    public static readonly Operation CreateWebhookEventType = new("createWebhookEventType", "POST", "/v1/webhook_event_types", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a tenant event type</summary>
    public static readonly Operation GetWebhookEventType = new("getWebhookEventType", "GET", "/v1/webhook_event_types/{webhook_event_type_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Archive a tenant event type</summary>
    public static readonly Operation ArchiveWebhookEventType = new("archiveWebhookEventType", "POST", "/v1/webhook_event_types/{webhook_event_type_id}/archive", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List the schema versions of a tenant event type</summary>
    public static readonly Operation ListWebhookEventTypeVersions = new("listWebhookEventTypeVersions", "GET", "/v1/webhook_event_types/{webhook_event_type_id}/versions", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Add a schema version to a tenant event type</summary>
    public static readonly Operation CreateWebhookEventTypeVersion = new("createWebhookEventTypeVersion", "POST", "/v1/webhook_event_types/{webhook_event_type_id}/versions", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a schema version of a tenant event type</summary>
    public static readonly Operation GetWebhookEventTypeVersion = new("getWebhookEventTypeVersion", "GET", "/v1/webhook_event_types/{webhook_event_type_id}/versions/{version}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List Relay's event catalog</summary>
    public static readonly Operation ListWebhookCatalog = new("listWebhookCatalog", "GET", "/v1/webhook_catalog", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List webhook endpoints</summary>
    public static readonly Operation ListWebhookEndpoints = new("listWebhookEndpoints", "GET", "/v1/webhook_endpoints", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create a webhook endpoint</summary>
    public static readonly Operation CreateWebhookEndpoint = new("createWebhookEndpoint", "POST", "/v1/webhook_endpoints", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a webhook endpoint</summary>
    public static readonly Operation GetWebhookEndpoint = new("getWebhookEndpoint", "GET", "/v1/webhook_endpoints/{webhook_endpoint_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Update a webhook endpoint</summary>
    public static readonly Operation UpdateWebhookEndpoint = new("updateWebhookEndpoint", "PATCH", "/v1/webhook_endpoints/{webhook_endpoint_id}", IdempotencyMode.Required, IfMatchMode.Optional, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Archive a webhook endpoint</summary>
    public static readonly Operation ArchiveWebhookEndpoint = new("archiveWebhookEndpoint", "POST", "/v1/webhook_endpoints/{webhook_endpoint_id}/archive", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Rotate a webhook endpoint's signing key</summary>
    public static readonly Operation RotateWebhookEndpointKey = new("rotateWebhookEndpointKey", "POST", "/v1/webhook_endpoints/{webhook_endpoint_id}/rotate_key", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Optional, "application/json", ResponseKind.Json);

    /// <summary>List the versions of an endpoint</summary>
    public static readonly Operation ListWebhookEndpointVersions = new("listWebhookEndpointVersions", "GET", "/v1/webhook_endpoints/{webhook_endpoint_id}/versions", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get a version of an endpoint</summary>
    public static readonly Operation GetWebhookEndpointVersion = new("getWebhookEndpointVersion", "GET", "/v1/webhook_endpoints/{webhook_endpoint_id}/versions/{version}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Pause a webhook endpoint</summary>
    public static readonly Operation PauseWebhookEndpoint = new("pauseWebhookEndpoint", "POST", "/v1/webhook_endpoints/{webhook_endpoint_id}/pause", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Resume a webhook endpoint</summary>
    public static readonly Operation ResumeWebhookEndpoint = new("resumeWebhookEndpoint", "POST", "/v1/webhook_endpoints/{webhook_endpoint_id}/resume", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get the health of an endpoint</summary>
    public static readonly Operation GetWebhookEndpointHealth = new("getWebhookEndpointHealth", "GET", "/v1/webhook_endpoints/{webhook_endpoint_id}/health", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Send a test event</summary>
    public static readonly Operation SendWebhookEndpointTestEvent = new("sendWebhookEndpointTestEvent", "POST", "/v1/webhook_endpoints/{webhook_endpoint_id}/test", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Optional, "application/json", ResponseKind.Json);

    /// <summary>Recover an endpoint</summary>
    public static readonly Operation RecoverWebhookEndpoint = new("recoverWebhookEndpoint", "POST", "/v1/webhook_endpoints/{webhook_endpoint_id}/recover", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Retry messages in bulk</summary>
    public static readonly Operation RetryWebhookEndpointMessages = new("retryWebhookEndpointMessages", "POST", "/v1/webhook_endpoints/{webhook_endpoint_id}/retry", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Replay events to an endpoint</summary>
    public static readonly Operation ReplayWebhookEndpointEvents = new("replayWebhookEndpointEvents", "POST", "/v1/webhook_endpoints/{webhook_endpoint_id}/replay", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Cancel scheduled retries</summary>
    public static readonly Operation CancelWebhookEndpointRetries = new("cancelWebhookEndpointRetries", "POST", "/v1/webhook_endpoints/{webhook_endpoint_id}/cancel_retries", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Optional, "application/json", ResponseKind.Json);

    /// <summary>List missed events</summary>
    public static readonly Operation ListWebhookEndpointMissedEvents = new("listWebhookEndpointMissedEvents", "GET", "/v1/webhook_endpoints/{webhook_endpoint_id}/missed_events", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List webhook events</summary>
    public static readonly Operation ListWebhookEvents = new("listWebhookEvents", "GET", "/v1/webhook_events", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List webhook messages</summary>
    public static readonly Operation ListWebhookMessages = new("listWebhookMessages", "GET", "/v1/webhook_messages", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get a webhook message</summary>
    public static readonly Operation GetWebhookMessage = new("getWebhookMessage", "GET", "/v1/webhook_messages/{webhook_message_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List the attempts of a message</summary>
    public static readonly Operation ListWebhookMessageAttempts = new("listWebhookMessageAttempts", "GET", "/v1/webhook_messages/{webhook_message_id}/attempts", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get an attempt of a message</summary>
    public static readonly Operation GetWebhookMessageAttempt = new("getWebhookMessageAttempt", "GET", "/v1/webhook_messages/{webhook_message_id}/attempts/{webhook_attempt_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Resend a webhook message</summary>
    public static readonly Operation ResendWebhookMessage = new("resendWebhookMessage", "POST", "/v1/webhook_messages/{webhook_message_id}/resend", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Cancel a webhook message</summary>
    public static readonly Operation CancelWebhookMessage = new("cancelWebhookMessage", "POST", "/v1/webhook_messages/{webhook_message_id}/cancel", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get the operations contacts</summary>
    public static readonly Operation GetOperationsContacts = new("getOperationsContacts", "GET", "/v1/operations_contacts", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Replace the operations contacts</summary>
    public static readonly Operation ReplaceOperationsContacts = new("replaceOperationsContacts", "PUT", "/v1/operations_contacts", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get the İYS configuration</summary>
    public static readonly Operation GetIysConfig = new("getIysConfig", "GET", "/v1/iys/config", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Replace the İYS configuration</summary>
    public static readonly Operation ReplaceIysConfig = new("replaceIysConfig", "PUT", "/v1/iys/config", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List the İYS brands</summary>
    public static readonly Operation ListIysBrands = new("listIysBrands", "GET", "/v1/iys/brands", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Test the İYS connection</summary>
    public static readonly Operation TestIysConnection = new("testIysConnection", "GET", "/v1/iys/connection_test", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List İYS uploads</summary>
    public static readonly Operation ListIysUploads = new("listIysUploads", "GET", "/v1/iys/uploads", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Put a subscriber's messaging conversation</summary>
    public static readonly Operation ReplaceSubscriberMessagingTarget = new("replaceSubscriberMessagingTarget", "PUT", "/v1/subscribers/{subscriber_id}/messaging_targets/{channel}", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Remove a subscriber's messaging conversation</summary>
    public static readonly Operation DeleteSubscriberMessagingTarget = new("deleteSubscriberMessagingTarget", "DELETE", "/v1/subscribers/{subscriber_id}/messaging_targets/{channel}", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Install a messaging channel identity in a workspace</summary>
    public static readonly Operation CreateMessagingInstallation = new("createMessagingInstallation", "POST", "/v1/messaging_installations", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List channel adapters</summary>
    public static readonly Operation ListChannelAdapters = new("listChannelAdapters", "GET", "/v1/channel_adapters", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List WhatsApp templates</summary>
    public static readonly Operation ListWhatsappTemplates = new("listWhatsappTemplates", "GET", "/v1/whatsapp/templates", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Register a WhatsApp template</summary>
    public static readonly Operation RegisterWhatsappTemplate = new("registerWhatsappTemplate", "POST", "/v1/whatsapp/templates", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a WhatsApp template</summary>
    public static readonly Operation GetWhatsappTemplate = new("getWhatsappTemplate", "GET", "/v1/whatsapp/templates/{whatsapp_template_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List provider accounts</summary>
    public static readonly Operation ListProviderAccounts = new("listProviderAccounts", "GET", "/v1/provider_accounts", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get a provider account</summary>
    public static readonly Operation GetProviderAccount = new("getProviderAccount", "GET", "/v1/provider_accounts/{provider_account_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Update a provider account</summary>
    public static readonly Operation UpdateProviderAccount = new("updateProviderAccount", "PATCH", "/v1/provider_accounts/{provider_account_id}", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Required, "application/merge-patch+json", ResponseKind.Json);

    /// <summary>Verify a provider account</summary>
    public static readonly Operation VerifyProviderAccount = new("verifyProviderAccount", "POST", "/v1/provider_accounts/{provider_account_id}/verify", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get the status of a provider account</summary>
    public static readonly Operation GetProviderAccountStatus = new("getProviderAccountStatus", "GET", "/v1/provider_accounts/{provider_account_id}/status", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Check the sending domains of an e-mail provider account</summary>
    public static readonly Operation GetProviderAccountEmailDomains = new("getProviderAccountEmailDomains", "GET", "/v1/provider_accounts/{provider_account_id}/email_domains", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List the e-mail warm-up plans</summary>
    public static readonly Operation ListEmailWarmupPlans = new("listEmailWarmupPlans", "GET", "/v1/email_warmup_plans", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Quote the cost of a paid channel</summary>
    public static readonly Operation QuoteChannelCost = new("quoteChannelCost", "GET", "/v1/channel_costs", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List provider invoices</summary>
    public static readonly Operation ListProviderInvoices = new("listProviderInvoices", "GET", "/v1/provider_invoices", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Record a provider invoice</summary>
    public static readonly Operation CreateProviderInvoice = new("createProviderInvoice", "POST", "/v1/provider_invoices", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a provider invoice</summary>
    public static readonly Operation GetProviderInvoice = new("getProviderInvoice", "GET", "/v1/provider_invoices/{provider_invoice_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List raw data exports</summary>
    public static readonly Operation ListExports = new("listExports", "GET", "/v1/exports", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Request a raw data export</summary>
    public static readonly Operation CreateExport = new("createExport", "POST", "/v1/exports", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a raw data export</summary>
    public static readonly Operation GetExport = new("getExport", "GET", "/v1/exports/{export_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List campaigns</summary>
    public static readonly Operation ListCampaigns = new("listCampaigns", "GET", "/v1/campaigns", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create a campaign</summary>
    public static readonly Operation CreateCampaign = new("createCampaign", "POST", "/v1/campaigns", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a campaign</summary>
    public static readonly Operation GetCampaign = new("getCampaign", "GET", "/v1/campaigns/{campaign_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Add recipients to a campaign</summary>
    public static readonly Operation AddCampaignRecipients = new("addCampaignRecipients", "POST", "/v1/campaigns/{campaign_id}/recipients", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Prepare a campaign</summary>
    public static readonly Operation PrepareCampaign = new("prepareCampaign", "POST", "/v1/campaigns/{campaign_id}/prepare", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Render the samples of a campaign</summary>
    public static readonly Operation GetCampaignSamples = new("getCampaignSamples", "GET", "/v1/campaigns/{campaign_id}/samples", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Approve the samples of a campaign</summary>
    public static readonly Operation ApproveCampaignSamples = new("approveCampaignSamples", "POST", "/v1/campaigns/{campaign_id}/approve_samples", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Trigger a campaign</summary>
    public static readonly Operation TriggerCampaign = new("triggerCampaign", "POST", "/v1/campaigns/{campaign_id}/trigger", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Cancel a campaign</summary>
    public static readonly Operation CancelCampaign = new("cancelCampaign", "POST", "/v1/campaigns/{campaign_id}/cancel", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get the delivery report</summary>
    public static readonly Operation GetDeliveryReport = new("getDeliveryReport", "GET", "/v1/reports/deliveries", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get the skip distribution</summary>
    public static readonly Operation GetSkipReport = new("getSkipReport", "GET", "/v1/reports/skips", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get the cost report</summary>
    public static readonly Operation GetCostReport = new("getCostReport", "GET", "/v1/reports/costs", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List sender identities</summary>
    public static readonly Operation ListSenderIdentities = new("listSenderIdentities", "GET", "/v1/sender_identities", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Create a sender identity</summary>
    public static readonly Operation CreateSenderIdentity = new("createSenderIdentity", "POST", "/v1/sender_identities", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a sender identity</summary>
    public static readonly Operation GetSenderIdentity = new("getSenderIdentity", "GET", "/v1/sender_identities/{sender_identity_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Update a sender identity</summary>
    public static readonly Operation UpdateSenderIdentity = new("updateSenderIdentity", "PATCH", "/v1/sender_identities/{sender_identity_id}", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Required, "application/merge-patch+json", ResponseKind.Json);

    /// <summary>Archive a sender identity</summary>
    public static readonly Operation ArchiveSenderIdentity = new("archiveSenderIdentity", "POST", "/v1/sender_identities/{sender_identity_id}/archive", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List channel identities</summary>
    public static readonly Operation ListChannelIdentities = new("listChannelIdentities", "GET", "/v1/channel_identities", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get a channel identity</summary>
    public static readonly Operation GetChannelIdentity = new("getChannelIdentity", "GET", "/v1/channel_identities/{channel_identity_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Update a channel identity</summary>
    public static readonly Operation UpdateChannelIdentity = new("updateChannelIdentity", "PATCH", "/v1/channel_identities/{channel_identity_id}", IdempotencyMode.Required, IfMatchMode.Required, BodyMode.Required, "application/merge-patch+json", ResponseKind.Json);

    /// <summary>Retire a channel identity</summary>
    public static readonly Operation ArchiveChannelIdentity = new("archiveChannelIdentity", "POST", "/v1/channel_identities/{channel_identity_id}/archive", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Upload a DMARC aggregate or TLS report</summary>
    public static readonly Operation UploadEmailReport = new("uploadEmailReport", "POST", "/v1/email_reports", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Summarize a domain's DMARC and TLS reports</summary>
    public static readonly Operation GetEmailReportSummary = new("getEmailReportSummary", "GET", "/v1/email_reports/summary", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>List recurrence rules</summary>
    public static readonly Operation ListRecurrences = new("listRecurrences", "GET", "/v1/recurrences", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Define a recurrence rule</summary>
    public static readonly Operation CreateRecurrence = new("createRecurrence", "POST", "/v1/recurrences", IdempotencyMode.Required, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>Get a recurrence rule</summary>
    public static readonly Operation GetRecurrence = new("getRecurrence", "GET", "/v1/recurrences/{recurrence_id}", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Cancel a recurrence rule</summary>
    public static readonly Operation CancelRecurrence = new("cancelRecurrence", "POST", "/v1/recurrences/{recurrence_id}/cancel", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Reset an active throttle</summary>
    public static readonly Operation ResetThrottle = new("resetThrottle", "POST", "/v1/throttles/{throttle_key}/reset", IdempotencyMode.Required, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Find a subscriber by phone or e-mail</summary>
    public static readonly Operation LookupSubscribers = new("lookupSubscribers", "POST", "/v1/subscriber_lookups", IdempotencyMode.None, IfMatchMode.None, BodyMode.Required, "application/json", ResponseKind.Json);

    /// <summary>List the rule dictionary</summary>
    public static readonly Operation ListRules = new("listRules", "GET", "/v1/rules", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get the tenant settings</summary>
    public static readonly Operation GetTenantSettings = new("getTenantSettings", "GET", "/v1/settings", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Where a route is used</summary>
    public static readonly Operation GetRouteUsage = new("getRouteUsage", "GET", "/v1/routes/{route_key}/usage", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Where an escalation policy is used</summary>
    public static readonly Operation GetEscalationPolicyUsage = new("getEscalationPolicyUsage", "GET", "/v1/escalation_policies/{policy_key}/usage", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Run the publication gate on the draft without publishing</summary>
    public static readonly Operation CheckWorkflowPublication = new("checkWorkflowPublication", "GET", "/v1/workflows/{workflow_key}/publication_check", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Run the publication gate on the draft without publishing</summary>
    public static readonly Operation CheckTemplatePublication = new("checkTemplatePublication", "GET", "/v1/templates/{template_key}/publication_check", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get the waitpoint figures</summary>
    public static readonly Operation GetWaitpointStats = new("getWaitpointStats", "GET", "/v1/waitpoint_stats", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get the A/B variant report</summary>
    public static readonly Operation GetVariantReport = new("getVariantReport", "GET", "/v1/reports/variants", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>Get the render and locale problem report</summary>
    public static readonly Operation GetRenderProblemReport = new("getRenderProblemReport", "GET", "/v1/reports/render_problems", IdempotencyMode.None, IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    /// <summary>All operations, in contract order.</summary>
    public static readonly IReadOnlyList<Operation> All =
    [
        CreateEvent,
        CreateEventBatch,
        GetEvent,
        CancelEvent,
        CancelEventsByKey,
        ListNotifications,
        GetNotification,
        CancelNotification,
        ListNotificationDeliveries,
        GetDeliveryHistory,
        ListSubscriberDecisions,
        CreateSubscriber,
        ListSubscribers,
        GetSubscriber,
        ReplaceSubscriber,
        UpdateSubscriber,
        DeleteSubscriber,
        BulkUpsertSubscribers,
        GetSubscriberPreferences,
        UpdateSubscriberPreferences,
        CreatePreferencePageLink,
        ListSubscriberConsents,
        ListSubscriberDevices,
        RegisterSubscriberDevice,
        DeleteSubscriberDevice,
        DeleteDeviceByToken,
        GetTimingSettings,
        SetTimingSettings,
        GetRealtimeOrigins,
        SetRealtimeOrigins,
        ListRoutes,
        CreateRoute,
        GetRoute,
        ReplaceRoute,
        ArchiveRoute,
        ListWorkflows,
        CreateWorkflow,
        GetWorkflow,
        ReplaceWorkflowDraft,
        PublishWorkflow,
        SetWorkflowManager,
        ListWorkflowVersions,
        GetWorkflowVersion,
        GetWorkflowVersionMermaid,
        PromoteWorkflowVersion,
        PreviewWorkflow,
        SendWorkflowTest,
        ListTemplates,
        CreateTemplate,
        GetTemplate,
        ReplaceTemplateDraft,
        PublishTemplate,
        ArchiveTemplate,
        ListTemplateVersions,
        GetTemplateVersion,
        PromoteTemplateVersion,
        GetTemplateTranslations,
        PreviewTemplate,
        PublishProducerTemplate,
        ListLayouts,
        CreateLayout,
        GetLayout,
        ReplaceLayoutDraft,
        PublishLayout,
        ArchiveLayout,
        ListLayoutVersions,
        GetLayoutVersion,
        PromoteLayoutVersion,
        ListPartials,
        CreatePartial,
        GetPartial,
        ReplacePartialDraft,
        PublishPartial,
        ArchivePartial,
        ListPartialVersions,
        GetPartialVersion,
        PromotePartialVersion,
        GetBrand,
        UpdateBrand,
        GetComplianceSettings,
        ReplaceComplianceSettings,
        GetDeliveryWindows,
        ReplaceDeliveryWindows,
        ListEventTypeMappings,
        CreateEventTypeMapping,
        GetEventTypeMapping,
        ReplaceEventTypeMapping,
        ArchiveEventTypeMapping,
        ListCategories,
        CreateCategory,
        GetCategory,
        UpdateCategory,
        ArchiveCategory,
        ListSubtenants,
        GetCategorySubtenantSetting,
        ReplaceCategorySubtenantSetting,
        GetCategoryEmailTracking,
        ReplaceCategoryEmailTracking,
        GetTemplateEmailTracking,
        ReplaceTemplateEmailTracking,
        ListSuppressions,
        CreateSuppression,
        LiftSuppression,
        GetSmsDestinationPolicy,
        SetSmsDestinationPolicy,
        ListSmsDestinationStops,
        LiftSmsDestinationStop,
        ListTestRecipients,
        CreateTestRecipient,
        RemoveTestRecipient,
        CreateInboxAnnouncement,
        GetInboxAnnouncement,
        RetractInboxAnnouncement,
        ListTopics,
        CreateTopic,
        GetTopic,
        ArchiveTopic,
        ListTopicSubscriptions,
        AddTopicSubscriptions,
        RemoveTopicSubscriptions,
        ListSubscriberSubscriptions,
        ListKillSwitches,
        EngageKillSwitch,
        GetKillSwitch,
        ReplaceKillSwitch,
        GetVirtualClock,
        AdvanceVirtualClock,
        ListSimulatedResults,
        ListSeedRecipients,
        ResetSeedRecipients,
        ListTestInboxMessages,
        ListWaitpoints,
        CreateWaitpoint,
        GetWaitpoint,
        CancelWaitpoint,
        HeartbeatWaitpoint,
        GetMailbox,
        LeaseMailboxRecords,
        AckMailboxRecords,
        PublishAgUiEvent,
        CallMcp,
        ListMailboxRecords,
        GetMailboxRecord,
        ListMailboxDeadLetters,
        SendMailboxMessage,
        ListMailboxRequests,
        GetMailboxEnvelope,
        SetMailboxSenderBlock,
        ReportMailboxAbuse,
        ListEscalationPolicies,
        GetEscalationPolicy,
        PutEscalationPolicy,
        ListEscalationPolicyVersions,
        ArchiveEscalationPolicy,
        ListAgents,
        CreateAgent,
        GetAgent,
        UpdateAgent,
        DeleteAgent,
        CreateAgentCeilingDecision,
        ListAgentCeilingHolds,
        ResumeAgent,
        ListWebhookConsumers,
        CreateWebhookConsumer,
        GetWebhookConsumer,
        UpdateWebhookConsumer,
        ArchiveWebhookConsumer,
        ListWebhookSources,
        CreateWebhookSource,
        GetWebhookSource,
        ArchiveWebhookSource,
        CreateWebhookPortalToken,
        ListWebhookEventTypes,
        CreateWebhookEventType,
        GetWebhookEventType,
        ArchiveWebhookEventType,
        ListWebhookEventTypeVersions,
        CreateWebhookEventTypeVersion,
        GetWebhookEventTypeVersion,
        ListWebhookCatalog,
        ListWebhookEndpoints,
        CreateWebhookEndpoint,
        GetWebhookEndpoint,
        UpdateWebhookEndpoint,
        ArchiveWebhookEndpoint,
        RotateWebhookEndpointKey,
        ListWebhookEndpointVersions,
        GetWebhookEndpointVersion,
        PauseWebhookEndpoint,
        ResumeWebhookEndpoint,
        GetWebhookEndpointHealth,
        SendWebhookEndpointTestEvent,
        RecoverWebhookEndpoint,
        RetryWebhookEndpointMessages,
        ReplayWebhookEndpointEvents,
        CancelWebhookEndpointRetries,
        ListWebhookEndpointMissedEvents,
        ListWebhookEvents,
        ListWebhookMessages,
        GetWebhookMessage,
        ListWebhookMessageAttempts,
        GetWebhookMessageAttempt,
        ResendWebhookMessage,
        CancelWebhookMessage,
        GetOperationsContacts,
        ReplaceOperationsContacts,
        GetIysConfig,
        ReplaceIysConfig,
        ListIysBrands,
        TestIysConnection,
        ListIysUploads,
        ReplaceSubscriberMessagingTarget,
        DeleteSubscriberMessagingTarget,
        CreateMessagingInstallation,
        ListChannelAdapters,
        ListWhatsappTemplates,
        RegisterWhatsappTemplate,
        GetWhatsappTemplate,
        ListProviderAccounts,
        GetProviderAccount,
        UpdateProviderAccount,
        VerifyProviderAccount,
        GetProviderAccountStatus,
        GetProviderAccountEmailDomains,
        ListEmailWarmupPlans,
        QuoteChannelCost,
        ListProviderInvoices,
        CreateProviderInvoice,
        GetProviderInvoice,
        ListExports,
        CreateExport,
        GetExport,
        ListCampaigns,
        CreateCampaign,
        GetCampaign,
        AddCampaignRecipients,
        PrepareCampaign,
        GetCampaignSamples,
        ApproveCampaignSamples,
        TriggerCampaign,
        CancelCampaign,
        GetDeliveryReport,
        GetSkipReport,
        GetCostReport,
        ListSenderIdentities,
        CreateSenderIdentity,
        GetSenderIdentity,
        UpdateSenderIdentity,
        ArchiveSenderIdentity,
        ListChannelIdentities,
        GetChannelIdentity,
        UpdateChannelIdentity,
        ArchiveChannelIdentity,
        UploadEmailReport,
        GetEmailReportSummary,
        ListRecurrences,
        CreateRecurrence,
        GetRecurrence,
        CancelRecurrence,
        ResetThrottle,
        LookupSubscribers,
        ListRules,
        GetTenantSettings,
        GetRouteUsage,
        GetEscalationPolicyUsage,
        CheckWorkflowPublication,
        CheckTemplatePublication,
        GetWaitpointStats,
        GetVariantReport,
        GetRenderProblemReport,
    ];
}
