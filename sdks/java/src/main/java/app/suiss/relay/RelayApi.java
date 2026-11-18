package app.suiss.relay;

import app.suiss.relay.params.*;
import com.fasterxml.jackson.databind.JsonNode;
import java.util.List;

/** Every operation of the Relay server API that an API client calls. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class RelayApi {
  private static final Operation CREATE_EVENT =
      new Operation(
          "createEvent",
          "POST",
          "/v1/events",
          Operation.Presence.OPTIONAL,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_EVENT_BATCH =
      new Operation(
          "createEventBatch",
          "POST",
          "/v1/events/batch",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_EVENT =
      new Operation(
          "getEvent",
          "GET",
          "/v1/events/{event_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CANCEL_EVENT =
      new Operation(
          "cancelEvent",
          "POST",
          "/v1/events/{event_id}/cancel",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.OPTIONAL,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CANCEL_EVENTS_BY_KEY =
      new Operation(
          "cancelEventsByKey",
          "POST",
          "/v1/events/cancel_by_key",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_NOTIFICATIONS =
      new Operation(
          "listNotifications",
          "GET",
          "/v1/notifications",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_NOTIFICATION =
      new Operation(
          "getNotification",
          "GET",
          "/v1/notifications/{notification_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CANCEL_NOTIFICATION =
      new Operation(
          "cancelNotification",
          "POST",
          "/v1/notifications/{notification_id}/cancel",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.OPTIONAL,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_NOTIFICATION_DELIVERIES =
      new Operation(
          "listNotificationDeliveries",
          "GET",
          "/v1/notifications/{notification_id}/deliveries",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_DELIVERY_HISTORY =
      new Operation(
          "getDeliveryHistory",
          "GET",
          "/v1/deliveries/{delivery_id}/history",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_SUBSCRIBER_DECISIONS =
      new Operation(
          "listSubscriberDecisions",
          "GET",
          "/v1/subscribers/{subscriber_id}/decisions",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_SUBSCRIBER =
      new Operation(
          "createSubscriber",
          "POST",
          "/v1/subscribers",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_SUBSCRIBERS =
      new Operation(
          "listSubscribers",
          "GET",
          "/v1/subscribers",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_SUBSCRIBER =
      new Operation(
          "getSubscriber",
          "GET",
          "/v1/subscribers/{subscriber_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_SUBSCRIBER =
      new Operation(
          "replaceSubscriber",
          "PUT",
          "/v1/subscribers/{subscriber_id}",
          Operation.Presence.REQUIRED,
          Operation.Presence.OPTIONAL,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation UPDATE_SUBSCRIBER =
      new Operation(
          "updateSubscriber",
          "PATCH",
          "/v1/subscribers/{subscriber_id}",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          "application/merge-patch+json",
          Operation.Response.JSON);
  private static final Operation DELETE_SUBSCRIBER =
      new Operation(
          "deleteSubscriber",
          "DELETE",
          "/v1/subscribers/{subscriber_id}",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation BULK_UPSERT_SUBSCRIBERS =
      new Operation(
          "bulkUpsertSubscribers",
          "POST",
          "/v1/subscribers/bulk",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_SUBSCRIBER_PREFERENCES =
      new Operation(
          "getSubscriberPreferences",
          "GET",
          "/v1/subscribers/{subscriber_id}/preferences",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation UPDATE_SUBSCRIBER_PREFERENCES =
      new Operation(
          "updateSubscriberPreferences",
          "PATCH",
          "/v1/subscribers/{subscriber_id}/preferences",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_SUBSCRIBER_CONSENTS =
      new Operation(
          "listSubscriberConsents",
          "GET",
          "/v1/subscribers/{subscriber_id}/consents",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_SUBSCRIBER_DEVICES =
      new Operation(
          "listSubscriberDevices",
          "GET",
          "/v1/subscribers/{subscriber_id}/devices",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REGISTER_SUBSCRIBER_DEVICE =
      new Operation(
          "registerSubscriberDevice",
          "POST",
          "/v1/subscribers/{subscriber_id}/devices",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation DELETE_SUBSCRIBER_DEVICE =
      new Operation(
          "deleteSubscriberDevice",
          "DELETE",
          "/v1/subscribers/{subscriber_id}/devices/{device_id}",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation DELETE_DEVICE_BY_TOKEN =
      new Operation(
          "deleteDeviceByToken",
          "DELETE",
          "/v1/devices/by-token",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_TIMING_SETTINGS =
      new Operation(
          "getTimingSettings",
          "GET",
          "/v1/timing_settings",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation SET_TIMING_SETTINGS =
      new Operation(
          "setTimingSettings",
          "PUT",
          "/v1/timing_settings",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_REALTIME_ORIGINS =
      new Operation(
          "getRealtimeOrigins",
          "GET",
          "/v1/realtime_origins",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation SET_REALTIME_ORIGINS =
      new Operation(
          "setRealtimeOrigins",
          "PUT",
          "/v1/realtime_origins",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_ROUTES =
      new Operation(
          "listRoutes",
          "GET",
          "/v1/routes",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_ROUTE =
      new Operation(
          "createRoute",
          "POST",
          "/v1/routes",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_ROUTE =
      new Operation(
          "getRoute",
          "GET",
          "/v1/routes/{route_key}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_ROUTE =
      new Operation(
          "replaceRoute",
          "PUT",
          "/v1/routes/{route_key}",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ARCHIVE_ROUTE =
      new Operation(
          "archiveRoute",
          "POST",
          "/v1/routes/{route_key}/archive",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_WORKFLOWS =
      new Operation(
          "listWorkflows",
          "GET",
          "/v1/workflows",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_WORKFLOW =
      new Operation(
          "createWorkflow",
          "POST",
          "/v1/workflows",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_WORKFLOW =
      new Operation(
          "getWorkflow",
          "GET",
          "/v1/workflows/{workflow_key}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_WORKFLOW_DRAFT =
      new Operation(
          "replaceWorkflowDraft",
          "PUT",
          "/v1/workflows/{workflow_key}",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation PUBLISH_WORKFLOW =
      new Operation(
          "publishWorkflow",
          "POST",
          "/v1/workflows/{workflow_key}/publish",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.OPTIONAL,
          "application/json",
          Operation.Response.JSON);
  private static final Operation SET_WORKFLOW_MANAGER =
      new Operation(
          "setWorkflowManager",
          "POST",
          "/v1/workflows/{workflow_key}/manager",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_WORKFLOW_VERSIONS =
      new Operation(
          "listWorkflowVersions",
          "GET",
          "/v1/workflows/{workflow_key}/versions",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_WORKFLOW_VERSION =
      new Operation(
          "getWorkflowVersion",
          "GET",
          "/v1/workflows/{workflow_key}/versions/{version}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_WORKFLOW_VERSION_MERMAID =
      new Operation(
          "getWorkflowVersionMermaid",
          "GET",
          "/v1/workflows/{workflow_key}/versions/{version}/mermaid",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.TEXT);
  private static final Operation PROMOTE_WORKFLOW_VERSION =
      new Operation(
          "promoteWorkflowVersion",
          "POST",
          "/v1/workflows/{workflow_key}/versions/{version}/promote",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation PREVIEW_WORKFLOW =
      new Operation(
          "previewWorkflow",
          "POST",
          "/v1/workflows/{workflow_key}/preview",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation SEND_WORKFLOW_TEST =
      new Operation(
          "sendWorkflowTest",
          "POST",
          "/v1/workflows/{workflow_key}/test",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_TEMPLATES =
      new Operation(
          "listTemplates",
          "GET",
          "/v1/templates",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_TEMPLATE =
      new Operation(
          "createTemplate",
          "POST",
          "/v1/templates",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_TEMPLATE =
      new Operation(
          "getTemplate",
          "GET",
          "/v1/templates/{template_key}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_TEMPLATE_DRAFT =
      new Operation(
          "replaceTemplateDraft",
          "PUT",
          "/v1/templates/{template_key}",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation PUBLISH_TEMPLATE =
      new Operation(
          "publishTemplate",
          "POST",
          "/v1/templates/{template_key}/publish",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.OPTIONAL,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ARCHIVE_TEMPLATE =
      new Operation(
          "archiveTemplate",
          "POST",
          "/v1/templates/{template_key}/archive",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_TEMPLATE_VERSIONS =
      new Operation(
          "listTemplateVersions",
          "GET",
          "/v1/templates/{template_key}/versions",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_TEMPLATE_VERSION =
      new Operation(
          "getTemplateVersion",
          "GET",
          "/v1/templates/{template_key}/versions/{version}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation PROMOTE_TEMPLATE_VERSION =
      new Operation(
          "promoteTemplateVersion",
          "POST",
          "/v1/templates/{template_key}/versions/{version}/promote",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_TEMPLATE_TRANSLATIONS =
      new Operation(
          "getTemplateTranslations",
          "GET",
          "/v1/templates/{template_key}/translations",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation PREVIEW_TEMPLATE =
      new Operation(
          "previewTemplate",
          "POST",
          "/v1/templates/{template_key}/preview",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation PUBLISH_PRODUCER_TEMPLATE =
      new Operation(
          "publishProducerTemplate",
          "PUT",
          "/v1/producer_templates/{template_key}",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_LAYOUTS =
      new Operation(
          "listLayouts",
          "GET",
          "/v1/layouts",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_LAYOUT =
      new Operation(
          "createLayout",
          "POST",
          "/v1/layouts",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_LAYOUT =
      new Operation(
          "getLayout",
          "GET",
          "/v1/layouts/{layout_key}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_LAYOUT_DRAFT =
      new Operation(
          "replaceLayoutDraft",
          "PUT",
          "/v1/layouts/{layout_key}",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation PUBLISH_LAYOUT =
      new Operation(
          "publishLayout",
          "POST",
          "/v1/layouts/{layout_key}/publish",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.OPTIONAL,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ARCHIVE_LAYOUT =
      new Operation(
          "archiveLayout",
          "POST",
          "/v1/layouts/{layout_key}/archive",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_LAYOUT_VERSIONS =
      new Operation(
          "listLayoutVersions",
          "GET",
          "/v1/layouts/{layout_key}/versions",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_LAYOUT_VERSION =
      new Operation(
          "getLayoutVersion",
          "GET",
          "/v1/layouts/{layout_key}/versions/{version}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation PROMOTE_LAYOUT_VERSION =
      new Operation(
          "promoteLayoutVersion",
          "POST",
          "/v1/layouts/{layout_key}/versions/{version}/promote",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_PARTIALS =
      new Operation(
          "listPartials",
          "GET",
          "/v1/partials",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_PARTIAL =
      new Operation(
          "createPartial",
          "POST",
          "/v1/partials",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_PARTIAL =
      new Operation(
          "getPartial",
          "GET",
          "/v1/partials/{partial_key}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_PARTIAL_DRAFT =
      new Operation(
          "replacePartialDraft",
          "PUT",
          "/v1/partials/{partial_key}",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation PUBLISH_PARTIAL =
      new Operation(
          "publishPartial",
          "POST",
          "/v1/partials/{partial_key}/publish",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.OPTIONAL,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ARCHIVE_PARTIAL =
      new Operation(
          "archivePartial",
          "POST",
          "/v1/partials/{partial_key}/archive",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_PARTIAL_VERSIONS =
      new Operation(
          "listPartialVersions",
          "GET",
          "/v1/partials/{partial_key}/versions",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_PARTIAL_VERSION =
      new Operation(
          "getPartialVersion",
          "GET",
          "/v1/partials/{partial_key}/versions/{version}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation PROMOTE_PARTIAL_VERSION =
      new Operation(
          "promotePartialVersion",
          "POST",
          "/v1/partials/{partial_key}/versions/{version}/promote",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_BRAND =
      new Operation(
          "getBrand",
          "GET",
          "/v1/brand",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation UPDATE_BRAND =
      new Operation(
          "updateBrand",
          "PATCH",
          "/v1/brand",
          Operation.Presence.REQUIRED,
          Operation.Presence.OPTIONAL,
          Operation.Presence.REQUIRED,
          "application/merge-patch+json",
          Operation.Response.JSON);
  private static final Operation GET_COMPLIANCE_SETTINGS =
      new Operation(
          "getComplianceSettings",
          "GET",
          "/v1/compliance_settings",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_COMPLIANCE_SETTINGS =
      new Operation(
          "replaceComplianceSettings",
          "PUT",
          "/v1/compliance_settings",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_DELIVERY_WINDOWS =
      new Operation(
          "getDeliveryWindows",
          "GET",
          "/v1/delivery_windows",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_DELIVERY_WINDOWS =
      new Operation(
          "replaceDeliveryWindows",
          "PUT",
          "/v1/delivery_windows",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_EVENT_TYPE_MAPPINGS =
      new Operation(
          "listEventTypeMappings",
          "GET",
          "/v1/event_type_mappings",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_EVENT_TYPE_MAPPING =
      new Operation(
          "createEventTypeMapping",
          "POST",
          "/v1/event_type_mappings",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_EVENT_TYPE_MAPPING =
      new Operation(
          "getEventTypeMapping",
          "GET",
          "/v1/event_type_mappings/{mapping_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_EVENT_TYPE_MAPPING =
      new Operation(
          "replaceEventTypeMapping",
          "PUT",
          "/v1/event_type_mappings/{mapping_id}",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ARCHIVE_EVENT_TYPE_MAPPING =
      new Operation(
          "archiveEventTypeMapping",
          "POST",
          "/v1/event_type_mappings/{mapping_id}/archive",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_CATEGORIES =
      new Operation(
          "listCategories",
          "GET",
          "/v1/categories",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_CATEGORY =
      new Operation(
          "createCategory",
          "POST",
          "/v1/categories",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_CATEGORY =
      new Operation(
          "getCategory",
          "GET",
          "/v1/categories/{category_key}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation UPDATE_CATEGORY =
      new Operation(
          "updateCategory",
          "PATCH",
          "/v1/categories/{category_key}",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          "application/merge-patch+json",
          Operation.Response.JSON);
  private static final Operation ARCHIVE_CATEGORY =
      new Operation(
          "archiveCategory",
          "POST",
          "/v1/categories/{category_key}/archive",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_CATEGORY_SUBTENANT_SETTING =
      new Operation(
          "getCategorySubtenantSetting",
          "GET",
          "/v1/categories/{category_key}/subtenants/{subtenant_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_CATEGORY_SUBTENANT_SETTING =
      new Operation(
          "replaceCategorySubtenantSetting",
          "PUT",
          "/v1/categories/{category_key}/subtenants/{subtenant_id}",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_CATEGORY_EMAIL_TRACKING =
      new Operation(
          "getCategoryEmailTracking",
          "GET",
          "/v1/categories/{category_key}/email_tracking",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_CATEGORY_EMAIL_TRACKING =
      new Operation(
          "replaceCategoryEmailTracking",
          "PUT",
          "/v1/categories/{category_key}/email_tracking",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_TEMPLATE_EMAIL_TRACKING =
      new Operation(
          "getTemplateEmailTracking",
          "GET",
          "/v1/templates/{template_key}/email_tracking",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_TEMPLATE_EMAIL_TRACKING =
      new Operation(
          "replaceTemplateEmailTracking",
          "PUT",
          "/v1/templates/{template_key}/email_tracking",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_SUPPRESSIONS =
      new Operation(
          "listSuppressions",
          "GET",
          "/v1/suppressions",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_SUPPRESSION =
      new Operation(
          "createSuppression",
          "POST",
          "/v1/suppressions",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIFT_SUPPRESSION =
      new Operation(
          "liftSuppression",
          "POST",
          "/v1/suppressions/{suppression_id}/lift",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_SMS_DESTINATION_POLICY =
      new Operation(
          "getSmsDestinationPolicy",
          "GET",
          "/v1/sms_destination_policy",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation SET_SMS_DESTINATION_POLICY =
      new Operation(
          "setSmsDestinationPolicy",
          "PUT",
          "/v1/sms_destination_policy",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_SMS_DESTINATION_STOPS =
      new Operation(
          "listSmsDestinationStops",
          "GET",
          "/v1/sms_destination_stops",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIFT_SMS_DESTINATION_STOP =
      new Operation(
          "liftSmsDestinationStop",
          "POST",
          "/v1/sms_destination_stops/{sms_destination_stop_id}/lift",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_TEST_RECIPIENTS =
      new Operation(
          "listTestRecipients",
          "GET",
          "/v1/test_recipients",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_TEST_RECIPIENT =
      new Operation(
          "createTestRecipient",
          "POST",
          "/v1/test_recipients",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REMOVE_TEST_RECIPIENT =
      new Operation(
          "removeTestRecipient",
          "POST",
          "/v1/test_recipients/{test_recipient_id}/remove",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_INBOX_ANNOUNCEMENT =
      new Operation(
          "createInboxAnnouncement",
          "POST",
          "/v1/inbox/announcements",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_INBOX_ANNOUNCEMENT =
      new Operation(
          "getInboxAnnouncement",
          "GET",
          "/v1/inbox/announcements/{announcement_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation RETRACT_INBOX_ANNOUNCEMENT =
      new Operation(
          "retractInboxAnnouncement",
          "POST",
          "/v1/inbox/announcements/{announcement_id}/retract",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_TOPICS =
      new Operation(
          "listTopics",
          "GET",
          "/v1/topics",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_TOPIC =
      new Operation(
          "createTopic",
          "POST",
          "/v1/topics",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_TOPIC =
      new Operation(
          "getTopic",
          "GET",
          "/v1/topics/{topic_key}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ARCHIVE_TOPIC =
      new Operation(
          "archiveTopic",
          "POST",
          "/v1/topics/{topic_key}/archive",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_TOPIC_SUBSCRIPTIONS =
      new Operation(
          "listTopicSubscriptions",
          "GET",
          "/v1/topics/{topic_key}/subscriptions",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ADD_TOPIC_SUBSCRIPTIONS =
      new Operation(
          "addTopicSubscriptions",
          "POST",
          "/v1/topics/{topic_key}/subscriptions",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REMOVE_TOPIC_SUBSCRIPTIONS =
      new Operation(
          "removeTopicSubscriptions",
          "POST",
          "/v1/topics/{topic_key}/subscriptions/remove",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_SUBSCRIBER_SUBSCRIPTIONS =
      new Operation(
          "listSubscriberSubscriptions",
          "GET",
          "/v1/subscribers/{subscriber_id}/subscriptions",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_KILL_SWITCHES =
      new Operation(
          "listKillSwitches",
          "GET",
          "/v1/kill_switches",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ENGAGE_KILL_SWITCH =
      new Operation(
          "engageKillSwitch",
          "POST",
          "/v1/kill_switches",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_KILL_SWITCH =
      new Operation(
          "getKillSwitch",
          "GET",
          "/v1/kill_switches/{kill_switch_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_KILL_SWITCH =
      new Operation(
          "replaceKillSwitch",
          "POST",
          "/v1/kill_switches/{kill_switch_id}/replace",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_VIRTUAL_CLOCK =
      new Operation(
          "getVirtualClock",
          "GET",
          "/v1/virtual_clock",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ADVANCE_VIRTUAL_CLOCK =
      new Operation(
          "advanceVirtualClock",
          "POST",
          "/v1/virtual_clock/advance",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_SIMULATED_RESULTS =
      new Operation(
          "listSimulatedResults",
          "GET",
          "/v1/test/simulated-results",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_SEED_RECIPIENTS =
      new Operation(
          "listSeedRecipients",
          "GET",
          "/v1/test/seed-recipients",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation RESET_SEED_RECIPIENTS =
      new Operation(
          "resetSeedRecipients",
          "POST",
          "/v1/test/seed-recipients/reset",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_TEST_INBOX_MESSAGES =
      new Operation(
          "listTestInboxMessages",
          "GET",
          "/v1/test/inbox",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_WAITPOINTS =
      new Operation(
          "listWaitpoints",
          "GET",
          "/v1/waitpoints",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_WAITPOINT =
      new Operation(
          "createWaitpoint",
          "POST",
          "/v1/waitpoints",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_WAITPOINT =
      new Operation(
          "getWaitpoint",
          "GET",
          "/v1/waitpoints/{waitpoint_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CANCEL_WAITPOINT =
      new Operation(
          "cancelWaitpoint",
          "POST",
          "/v1/waitpoints/{waitpoint_id}/cancel",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation HEARTBEAT_WAITPOINT =
      new Operation(
          "heartbeatWaitpoint",
          "POST",
          "/v1/waitpoints/{waitpoint_id}/heartbeat",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_MAILBOX =
      new Operation(
          "getMailbox",
          "GET",
          "/v1/mailbox",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LEASE_MAILBOX_RECORDS =
      new Operation(
          "leaseMailboxRecords",
          "POST",
          "/v1/mailbox/leases",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.OPTIONAL,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ACK_MAILBOX_RECORDS =
      new Operation(
          "ackMailboxRecords",
          "POST",
          "/v1/mailbox/acks",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation PUBLISH_AG_UI_EVENT =
      new Operation(
          "publishAgUiEvent",
          "POST",
          "/v1/agui/events",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CALL_MCP =
      new Operation(
          "callMcp",
          "POST",
          "/v1/mcp",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_MAILBOX_RECORDS =
      new Operation(
          "listMailboxRecords",
          "GET",
          "/v1/mailbox/records",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_MAILBOX_RECORD =
      new Operation(
          "getMailboxRecord",
          "GET",
          "/v1/mailbox/records/{record_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_MAILBOX_DEAD_LETTERS =
      new Operation(
          "listMailboxDeadLetters",
          "GET",
          "/v1/mailbox/dead_letters",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation SEND_MAILBOX_MESSAGE =
      new Operation(
          "sendMailboxMessage",
          "POST",
          "/v1/mailbox/messages",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_MAILBOX_REQUESTS =
      new Operation(
          "listMailboxRequests",
          "GET",
          "/v1/mailbox/requests",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_MAILBOX_ENVELOPE =
      new Operation(
          "getMailboxEnvelope",
          "GET",
          "/v1/mailbox/envelopes",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation SET_MAILBOX_SENDER_BLOCK =
      new Operation(
          "setMailboxSenderBlock",
          "POST",
          "/v1/mailbox/blocks",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPORT_MAILBOX_ABUSE =
      new Operation(
          "reportMailboxAbuse",
          "POST",
          "/v1/mailbox/abuse_reports",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_ESCALATION_POLICIES =
      new Operation(
          "listEscalationPolicies",
          "GET",
          "/v1/escalation_policies",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_ESCALATION_POLICY =
      new Operation(
          "getEscalationPolicy",
          "GET",
          "/v1/escalation_policies/{policy_key}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation PUT_ESCALATION_POLICY =
      new Operation(
          "putEscalationPolicy",
          "PUT",
          "/v1/escalation_policies/{policy_key}",
          Operation.Presence.REQUIRED,
          Operation.Presence.OPTIONAL,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_ESCALATION_POLICY_VERSIONS =
      new Operation(
          "listEscalationPolicyVersions",
          "GET",
          "/v1/escalation_policies/{policy_key}/versions",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ARCHIVE_ESCALATION_POLICY =
      new Operation(
          "archiveEscalationPolicy",
          "POST",
          "/v1/escalation_policies/{policy_key}/archive",
          Operation.Presence.REQUIRED,
          Operation.Presence.OPTIONAL,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_AGENTS =
      new Operation(
          "listAgents",
          "GET",
          "/v1/agents",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_AGENT =
      new Operation(
          "createAgent",
          "POST",
          "/v1/agents",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_AGENT =
      new Operation(
          "getAgent",
          "GET",
          "/v1/agents/{agent_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation UPDATE_AGENT =
      new Operation(
          "updateAgent",
          "PATCH",
          "/v1/agents/{agent_id}",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          "application/merge-patch+json",
          Operation.Response.JSON);
  private static final Operation DELETE_AGENT =
      new Operation(
          "deleteAgent",
          "DELETE",
          "/v1/agents/{agent_id}",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_AGENT_CEILING_DECISION =
      new Operation(
          "createAgentCeilingDecision",
          "POST",
          "/v1/agents/{agent_id}/ceiling_decisions",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_AGENT_CEILING_HOLDS =
      new Operation(
          "listAgentCeilingHolds",
          "GET",
          "/v1/agents/{agent_id}/ceiling_holds",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation RESUME_AGENT =
      new Operation(
          "resumeAgent",
          "POST",
          "/v1/agents/{agent_id}/resume",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_WEBHOOK_CONSUMERS =
      new Operation(
          "listWebhookConsumers",
          "GET",
          "/v1/webhook_consumers",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_WEBHOOK_CONSUMER =
      new Operation(
          "createWebhookConsumer",
          "POST",
          "/v1/webhook_consumers",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_WEBHOOK_CONSUMER =
      new Operation(
          "getWebhookConsumer",
          "GET",
          "/v1/webhook_consumers/{webhook_consumer_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation UPDATE_WEBHOOK_CONSUMER =
      new Operation(
          "updateWebhookConsumer",
          "PATCH",
          "/v1/webhook_consumers/{webhook_consumer_id}",
          Operation.Presence.REQUIRED,
          Operation.Presence.OPTIONAL,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ARCHIVE_WEBHOOK_CONSUMER =
      new Operation(
          "archiveWebhookConsumer",
          "POST",
          "/v1/webhook_consumers/{webhook_consumer_id}/archive",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_WEBHOOK_SOURCES =
      new Operation(
          "listWebhookSources",
          "GET",
          "/v1/webhook_sources",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_WEBHOOK_SOURCE =
      new Operation(
          "createWebhookSource",
          "POST",
          "/v1/webhook_sources",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_WEBHOOK_SOURCE =
      new Operation(
          "getWebhookSource",
          "GET",
          "/v1/webhook_sources/{webhook_source_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ARCHIVE_WEBHOOK_SOURCE =
      new Operation(
          "archiveWebhookSource",
          "POST",
          "/v1/webhook_sources/{webhook_source_id}/archive",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_WEBHOOK_PORTAL_TOKEN =
      new Operation(
          "createWebhookPortalToken",
          "POST",
          "/v1/webhook_consumers/{webhook_consumer_id}/portal_tokens",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_WEBHOOK_EVENT_TYPES =
      new Operation(
          "listWebhookEventTypes",
          "GET",
          "/v1/webhook_event_types",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_WEBHOOK_EVENT_TYPE =
      new Operation(
          "createWebhookEventType",
          "POST",
          "/v1/webhook_event_types",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_WEBHOOK_EVENT_TYPE =
      new Operation(
          "getWebhookEventType",
          "GET",
          "/v1/webhook_event_types/{webhook_event_type_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ARCHIVE_WEBHOOK_EVENT_TYPE =
      new Operation(
          "archiveWebhookEventType",
          "POST",
          "/v1/webhook_event_types/{webhook_event_type_id}/archive",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_WEBHOOK_EVENT_TYPE_VERSIONS =
      new Operation(
          "listWebhookEventTypeVersions",
          "GET",
          "/v1/webhook_event_types/{webhook_event_type_id}/versions",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_WEBHOOK_EVENT_TYPE_VERSION =
      new Operation(
          "createWebhookEventTypeVersion",
          "POST",
          "/v1/webhook_event_types/{webhook_event_type_id}/versions",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_WEBHOOK_EVENT_TYPE_VERSION =
      new Operation(
          "getWebhookEventTypeVersion",
          "GET",
          "/v1/webhook_event_types/{webhook_event_type_id}/versions/{version}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_WEBHOOK_CATALOG =
      new Operation(
          "listWebhookCatalog",
          "GET",
          "/v1/webhook_catalog",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_WEBHOOK_ENDPOINTS =
      new Operation(
          "listWebhookEndpoints",
          "GET",
          "/v1/webhook_endpoints",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_WEBHOOK_ENDPOINT =
      new Operation(
          "createWebhookEndpoint",
          "POST",
          "/v1/webhook_endpoints",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_WEBHOOK_ENDPOINT =
      new Operation(
          "getWebhookEndpoint",
          "GET",
          "/v1/webhook_endpoints/{webhook_endpoint_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation UPDATE_WEBHOOK_ENDPOINT =
      new Operation(
          "updateWebhookEndpoint",
          "PATCH",
          "/v1/webhook_endpoints/{webhook_endpoint_id}",
          Operation.Presence.REQUIRED,
          Operation.Presence.OPTIONAL,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ARCHIVE_WEBHOOK_ENDPOINT =
      new Operation(
          "archiveWebhookEndpoint",
          "POST",
          "/v1/webhook_endpoints/{webhook_endpoint_id}/archive",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ROTATE_WEBHOOK_ENDPOINT_KEY =
      new Operation(
          "rotateWebhookEndpointKey",
          "POST",
          "/v1/webhook_endpoints/{webhook_endpoint_id}/rotate_key",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.OPTIONAL,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_WEBHOOK_ENDPOINT_VERSIONS =
      new Operation(
          "listWebhookEndpointVersions",
          "GET",
          "/v1/webhook_endpoints/{webhook_endpoint_id}/versions",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_WEBHOOK_ENDPOINT_VERSION =
      new Operation(
          "getWebhookEndpointVersion",
          "GET",
          "/v1/webhook_endpoints/{webhook_endpoint_id}/versions/{version}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation PAUSE_WEBHOOK_ENDPOINT =
      new Operation(
          "pauseWebhookEndpoint",
          "POST",
          "/v1/webhook_endpoints/{webhook_endpoint_id}/pause",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation RESUME_WEBHOOK_ENDPOINT =
      new Operation(
          "resumeWebhookEndpoint",
          "POST",
          "/v1/webhook_endpoints/{webhook_endpoint_id}/resume",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_WEBHOOK_ENDPOINT_HEALTH =
      new Operation(
          "getWebhookEndpointHealth",
          "GET",
          "/v1/webhook_endpoints/{webhook_endpoint_id}/health",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation SEND_WEBHOOK_ENDPOINT_TEST_EVENT =
      new Operation(
          "sendWebhookEndpointTestEvent",
          "POST",
          "/v1/webhook_endpoints/{webhook_endpoint_id}/test",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.OPTIONAL,
          "application/json",
          Operation.Response.JSON);
  private static final Operation RECOVER_WEBHOOK_ENDPOINT =
      new Operation(
          "recoverWebhookEndpoint",
          "POST",
          "/v1/webhook_endpoints/{webhook_endpoint_id}/recover",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation RETRY_WEBHOOK_ENDPOINT_MESSAGES =
      new Operation(
          "retryWebhookEndpointMessages",
          "POST",
          "/v1/webhook_endpoints/{webhook_endpoint_id}/retry",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLAY_WEBHOOK_ENDPOINT_EVENTS =
      new Operation(
          "replayWebhookEndpointEvents",
          "POST",
          "/v1/webhook_endpoints/{webhook_endpoint_id}/replay",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CANCEL_WEBHOOK_ENDPOINT_RETRIES =
      new Operation(
          "cancelWebhookEndpointRetries",
          "POST",
          "/v1/webhook_endpoints/{webhook_endpoint_id}/cancel_retries",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.OPTIONAL,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_WEBHOOK_ENDPOINT_MISSED_EVENTS =
      new Operation(
          "listWebhookEndpointMissedEvents",
          "GET",
          "/v1/webhook_endpoints/{webhook_endpoint_id}/missed_events",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_WEBHOOK_EVENTS =
      new Operation(
          "listWebhookEvents",
          "GET",
          "/v1/webhook_events",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_WEBHOOK_MESSAGES =
      new Operation(
          "listWebhookMessages",
          "GET",
          "/v1/webhook_messages",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_WEBHOOK_MESSAGE =
      new Operation(
          "getWebhookMessage",
          "GET",
          "/v1/webhook_messages/{webhook_message_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_WEBHOOK_MESSAGE_ATTEMPTS =
      new Operation(
          "listWebhookMessageAttempts",
          "GET",
          "/v1/webhook_messages/{webhook_message_id}/attempts",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_WEBHOOK_MESSAGE_ATTEMPT =
      new Operation(
          "getWebhookMessageAttempt",
          "GET",
          "/v1/webhook_messages/{webhook_message_id}/attempts/{webhook_attempt_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation RESEND_WEBHOOK_MESSAGE =
      new Operation(
          "resendWebhookMessage",
          "POST",
          "/v1/webhook_messages/{webhook_message_id}/resend",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CANCEL_WEBHOOK_MESSAGE =
      new Operation(
          "cancelWebhookMessage",
          "POST",
          "/v1/webhook_messages/{webhook_message_id}/cancel",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_OPERATIONS_CONTACTS =
      new Operation(
          "getOperationsContacts",
          "GET",
          "/v1/operations_contacts",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_OPERATIONS_CONTACTS =
      new Operation(
          "replaceOperationsContacts",
          "PUT",
          "/v1/operations_contacts",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_IYS_CONFIG =
      new Operation(
          "getIysConfig",
          "GET",
          "/v1/iys/config",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_IYS_CONFIG =
      new Operation(
          "replaceIysConfig",
          "PUT",
          "/v1/iys/config",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_IYS_BRANDS =
      new Operation(
          "listIysBrands",
          "GET",
          "/v1/iys/brands",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation TEST_IYS_CONNECTION =
      new Operation(
          "testIysConnection",
          "GET",
          "/v1/iys/connection_test",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_IYS_UPLOADS =
      new Operation(
          "listIysUploads",
          "GET",
          "/v1/iys/uploads",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REPLACE_SUBSCRIBER_MESSAGING_TARGET =
      new Operation(
          "replaceSubscriberMessagingTarget",
          "PUT",
          "/v1/subscribers/{subscriber_id}/messaging_targets/{channel}",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation DELETE_SUBSCRIBER_MESSAGING_TARGET =
      new Operation(
          "deleteSubscriberMessagingTarget",
          "DELETE",
          "/v1/subscribers/{subscriber_id}/messaging_targets/{channel}",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_MESSAGING_INSTALLATION =
      new Operation(
          "createMessagingInstallation",
          "POST",
          "/v1/messaging_installations",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_CHANNEL_ADAPTERS =
      new Operation(
          "listChannelAdapters",
          "GET",
          "/v1/channel_adapters",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_WHATSAPP_TEMPLATES =
      new Operation(
          "listWhatsappTemplates",
          "GET",
          "/v1/whatsapp/templates",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation REGISTER_WHATSAPP_TEMPLATE =
      new Operation(
          "registerWhatsappTemplate",
          "POST",
          "/v1/whatsapp/templates",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_WHATSAPP_TEMPLATE =
      new Operation(
          "getWhatsappTemplate",
          "GET",
          "/v1/whatsapp/templates/{whatsapp_template_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_PROVIDER_ACCOUNTS =
      new Operation(
          "listProviderAccounts",
          "GET",
          "/v1/provider_accounts",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_PROVIDER_ACCOUNT =
      new Operation(
          "getProviderAccount",
          "GET",
          "/v1/provider_accounts/{provider_account_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation UPDATE_PROVIDER_ACCOUNT =
      new Operation(
          "updateProviderAccount",
          "PATCH",
          "/v1/provider_accounts/{provider_account_id}",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          "application/merge-patch+json",
          Operation.Response.JSON);
  private static final Operation VERIFY_PROVIDER_ACCOUNT =
      new Operation(
          "verifyProviderAccount",
          "POST",
          "/v1/provider_accounts/{provider_account_id}/verify",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_PROVIDER_ACCOUNT_STATUS =
      new Operation(
          "getProviderAccountStatus",
          "GET",
          "/v1/provider_accounts/{provider_account_id}/status",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_PROVIDER_ACCOUNT_EMAIL_DOMAINS =
      new Operation(
          "getProviderAccountEmailDomains",
          "GET",
          "/v1/provider_accounts/{provider_account_id}/email_domains",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_EMAIL_WARMUP_PLANS =
      new Operation(
          "listEmailWarmupPlans",
          "GET",
          "/v1/email_warmup_plans",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation QUOTE_CHANNEL_COST =
      new Operation(
          "quoteChannelCost",
          "GET",
          "/v1/channel_costs",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_PROVIDER_INVOICES =
      new Operation(
          "listProviderInvoices",
          "GET",
          "/v1/provider_invoices",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_PROVIDER_INVOICE =
      new Operation(
          "createProviderInvoice",
          "POST",
          "/v1/provider_invoices",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_PROVIDER_INVOICE =
      new Operation(
          "getProviderInvoice",
          "GET",
          "/v1/provider_invoices/{provider_invoice_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_EXPORTS =
      new Operation(
          "listExports",
          "GET",
          "/v1/exports",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_EXPORT =
      new Operation(
          "createExport",
          "POST",
          "/v1/exports",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_EXPORT =
      new Operation(
          "getExport",
          "GET",
          "/v1/exports/{export_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_CAMPAIGNS =
      new Operation(
          "listCampaigns",
          "GET",
          "/v1/campaigns",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_CAMPAIGN =
      new Operation(
          "createCampaign",
          "POST",
          "/v1/campaigns",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_CAMPAIGN =
      new Operation(
          "getCampaign",
          "GET",
          "/v1/campaigns/{campaign_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation ADD_CAMPAIGN_RECIPIENTS =
      new Operation(
          "addCampaignRecipients",
          "POST",
          "/v1/campaigns/{campaign_id}/recipients",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation PREPARE_CAMPAIGN =
      new Operation(
          "prepareCampaign",
          "POST",
          "/v1/campaigns/{campaign_id}/prepare",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_CAMPAIGN_SAMPLES =
      new Operation(
          "getCampaignSamples",
          "GET",
          "/v1/campaigns/{campaign_id}/samples",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation APPROVE_CAMPAIGN_SAMPLES =
      new Operation(
          "approveCampaignSamples",
          "POST",
          "/v1/campaigns/{campaign_id}/approve_samples",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation TRIGGER_CAMPAIGN =
      new Operation(
          "triggerCampaign",
          "POST",
          "/v1/campaigns/{campaign_id}/trigger",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CANCEL_CAMPAIGN =
      new Operation(
          "cancelCampaign",
          "POST",
          "/v1/campaigns/{campaign_id}/cancel",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_DELIVERY_REPORT =
      new Operation(
          "getDeliveryReport",
          "GET",
          "/v1/reports/deliveries",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_SKIP_REPORT =
      new Operation(
          "getSkipReport",
          "GET",
          "/v1/reports/skips",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_COST_REPORT =
      new Operation(
          "getCostReport",
          "GET",
          "/v1/reports/costs",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_SENDER_IDENTITIES =
      new Operation(
          "listSenderIdentities",
          "GET",
          "/v1/sender_identities",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_SENDER_IDENTITY =
      new Operation(
          "createSenderIdentity",
          "POST",
          "/v1/sender_identities",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_SENDER_IDENTITY =
      new Operation(
          "getSenderIdentity",
          "GET",
          "/v1/sender_identities/{sender_identity_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation UPDATE_SENDER_IDENTITY =
      new Operation(
          "updateSenderIdentity",
          "PATCH",
          "/v1/sender_identities/{sender_identity_id}",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          "application/merge-patch+json",
          Operation.Response.JSON);
  private static final Operation ARCHIVE_SENDER_IDENTITY =
      new Operation(
          "archiveSenderIdentity",
          "POST",
          "/v1/sender_identities/{sender_identity_id}/archive",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_CHANNEL_IDENTITIES =
      new Operation(
          "listChannelIdentities",
          "GET",
          "/v1/channel_identities",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_CHANNEL_IDENTITY =
      new Operation(
          "getChannelIdentity",
          "GET",
          "/v1/channel_identities/{channel_identity_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation UPDATE_CHANNEL_IDENTITY =
      new Operation(
          "updateChannelIdentity",
          "PATCH",
          "/v1/channel_identities/{channel_identity_id}",
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          Operation.Presence.REQUIRED,
          "application/merge-patch+json",
          Operation.Response.JSON);
  private static final Operation ARCHIVE_CHANNEL_IDENTITY =
      new Operation(
          "archiveChannelIdentity",
          "POST",
          "/v1/channel_identities/{channel_identity_id}/archive",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation UPLOAD_EMAIL_REPORT =
      new Operation(
          "uploadEmailReport",
          "POST",
          "/v1/email_reports",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_EMAIL_REPORT_SUMMARY =
      new Operation(
          "getEmailReportSummary",
          "GET",
          "/v1/email_reports/summary",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation LIST_RECURRENCES =
      new Operation(
          "listRecurrences",
          "GET",
          "/v1/recurrences",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CREATE_RECURRENCE =
      new Operation(
          "createRecurrence",
          "POST",
          "/v1/recurrences",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.REQUIRED,
          "application/json",
          Operation.Response.JSON);
  private static final Operation GET_RECURRENCE =
      new Operation(
          "getRecurrence",
          "GET",
          "/v1/recurrences/{recurrence_id}",
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation CANCEL_RECURRENCE =
      new Operation(
          "cancelRecurrence",
          "POST",
          "/v1/recurrences/{recurrence_id}/cancel",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);
  private static final Operation RESET_THROTTLE =
      new Operation(
          "resetThrottle",
          "POST",
          "/v1/throttles/{throttle_key}/reset",
          Operation.Presence.REQUIRED,
          Operation.Presence.NONE,
          Operation.Presence.NONE,
          "application/json",
          Operation.Response.JSON);

  private final Requester requester;

  RelayApi(Requester requester) {
    this.requester = requester;
  }

  /**
   * Send an event.
   *
   * <p>{@code POST /v1/events}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createEvent(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_EVENT, List.of(), null, body, options);
  }

  /**
   * Send an event.
   *
   * <p>{@code POST /v1/events}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createEvent(JsonNode body) {
    return createEvent(body, RequestOptions.none());
  }

  /**
   * Send a batch of events.
   *
   * <p>{@code POST /v1/events/batch}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createEventBatch(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_EVENT_BATCH, List.of(), null, body, options);
  }

  /**
   * Send a batch of events.
   *
   * <p>{@code POST /v1/events/batch}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createEventBatch(JsonNode body) {
    return createEventBatch(body, RequestOptions.none());
  }

  /**
   * Get an event.
   *
   * <p>{@code GET /v1/events/{event_id}}
   *
   * @param eventId the {@code event_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getEvent(String eventId, RequestOptions options) {
    return requester.json(GET_EVENT, List.of(eventId), null, null, options);
  }

  /**
   * Get an event.
   *
   * <p>{@code GET /v1/events/{event_id}}
   *
   * @param eventId the {@code event_id} path parameter
   * @return the response body
   */
  public JsonNode getEvent(String eventId) {
    return getEvent(eventId, RequestOptions.none());
  }

  /**
   * Cancel an event.
   *
   * <p>{@code POST /v1/events/{event_id}/cancel}
   *
   * @param eventId the {@code event_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode cancelEvent(String eventId, JsonNode body, RequestOptions options) {
    return requester.json(CANCEL_EVENT, List.of(eventId), null, body, options);
  }

  /**
   * Cancel an event.
   *
   * <p>{@code POST /v1/events/{event_id}/cancel}
   *
   * @param eventId the {@code event_id} path parameter
   * @return the response body
   */
  public JsonNode cancelEvent(String eventId) {
    return cancelEvent(eventId, null, RequestOptions.none());
  }

  /**
   * Cancel by cancellation key.
   *
   * <p>{@code POST /v1/events/cancel_by_key}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode cancelEventsByKey(JsonNode body, RequestOptions options) {
    return requester.json(CANCEL_EVENTS_BY_KEY, List.of(), null, body, options);
  }

  /**
   * Cancel by cancellation key.
   *
   * <p>{@code POST /v1/events/cancel_by_key}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode cancelEventsByKey(JsonNode body) {
    return cancelEventsByKey(body, RequestOptions.none());
  }

  /**
   * List notifications.
   *
   * <p>{@code GET /v1/notifications}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listNotifications(ListNotificationsParams params, RequestOptions options) {
    return requester.page(LIST_NOTIFICATIONS, List.of(), params, options);
  }

  /**
   * List notifications.
   *
   * <p>{@code GET /v1/notifications}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listNotifications() {
    return listNotifications(null, RequestOptions.none());
  }

  /**
   * Get a notification.
   *
   * <p>{@code GET /v1/notifications/{notification_id}}
   *
   * @param notificationId the {@code notification_id} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode getNotification(
      String notificationId, GetNotificationParams params, RequestOptions options) {
    return requester.json(GET_NOTIFICATION, List.of(notificationId), params, null, options);
  }

  /**
   * Get a notification.
   *
   * <p>{@code GET /v1/notifications/{notification_id}}
   *
   * @param notificationId the {@code notification_id} path parameter
   * @return the response body
   */
  public JsonNode getNotification(String notificationId) {
    return getNotification(notificationId, null, RequestOptions.none());
  }

  /**
   * Cancel a notification.
   *
   * <p>{@code POST /v1/notifications/{notification_id}/cancel}
   *
   * @param notificationId the {@code notification_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode cancelNotification(String notificationId, JsonNode body, RequestOptions options) {
    return requester.json(CANCEL_NOTIFICATION, List.of(notificationId), null, body, options);
  }

  /**
   * Cancel a notification.
   *
   * <p>{@code POST /v1/notifications/{notification_id}/cancel}
   *
   * @param notificationId the {@code notification_id} path parameter
   * @return the response body
   */
  public JsonNode cancelNotification(String notificationId) {
    return cancelNotification(notificationId, null, RequestOptions.none());
  }

  /**
   * List deliveries of a notification.
   *
   * <p>{@code GET /v1/notifications/{notification_id}/deliveries}
   *
   * @param notificationId the {@code notification_id} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listNotificationDeliveries(
      String notificationId, ListNotificationDeliveriesParams params, RequestOptions options) {
    return requester.page(LIST_NOTIFICATION_DELIVERIES, List.of(notificationId), params, options);
  }

  /**
   * List deliveries of a notification.
   *
   * <p>{@code GET /v1/notifications/{notification_id}/deliveries}
   *
   * @param notificationId the {@code notification_id} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listNotificationDeliveries(String notificationId) {
    return listNotificationDeliveries(notificationId, null, RequestOptions.none());
  }

  /**
   * Get attempt history and ledger of a delivery.
   *
   * <p>{@code GET /v1/deliveries/{delivery_id}/history}
   *
   * @param deliveryId the {@code delivery_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getDeliveryHistory(String deliveryId, RequestOptions options) {
    return requester.json(GET_DELIVERY_HISTORY, List.of(deliveryId), null, null, options);
  }

  /**
   * Get attempt history and ledger of a delivery.
   *
   * <p>{@code GET /v1/deliveries/{delivery_id}/history}
   *
   * @param deliveryId the {@code delivery_id} path parameter
   * @return the response body
   */
  public JsonNode getDeliveryHistory(String deliveryId) {
    return getDeliveryHistory(deliveryId, RequestOptions.none());
  }

  /**
   * Explain why a subscriber did or did not get notifications.
   *
   * <p>{@code GET /v1/subscribers/{subscriber_id}/decisions}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listSubscriberDecisions(
      String subscriberId, ListSubscriberDecisionsParams params, RequestOptions options) {
    return requester.page(LIST_SUBSCRIBER_DECISIONS, List.of(subscriberId), params, options);
  }

  /**
   * Explain why a subscriber did or did not get notifications.
   *
   * <p>{@code GET /v1/subscribers/{subscriber_id}/decisions}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listSubscriberDecisions(String subscriberId) {
    return listSubscriberDecisions(subscriberId, null, RequestOptions.none());
  }

  /**
   * Create a subscriber.
   *
   * <p>{@code POST /v1/subscribers}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createSubscriber(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_SUBSCRIBER, List.of(), null, body, options);
  }

  /**
   * Create a subscriber.
   *
   * <p>{@code POST /v1/subscribers}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createSubscriber(JsonNode body) {
    return createSubscriber(body, RequestOptions.none());
  }

  /**
   * List subscribers.
   *
   * <p>{@code GET /v1/subscribers}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listSubscribers(ListSubscribersParams params, RequestOptions options) {
    return requester.page(LIST_SUBSCRIBERS, List.of(), params, options);
  }

  /**
   * List subscribers.
   *
   * <p>{@code GET /v1/subscribers}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listSubscribers() {
    return listSubscribers(null, RequestOptions.none());
  }

  /**
   * Get a subscriber.
   *
   * <p>{@code GET /v1/subscribers/{subscriber_id}}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getSubscriber(String subscriberId, RequestOptions options) {
    return requester.json(GET_SUBSCRIBER, List.of(subscriberId), null, null, options);
  }

  /**
   * Get a subscriber.
   *
   * <p>{@code GET /v1/subscribers/{subscriber_id}}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @return the response body
   */
  public JsonNode getSubscriber(String subscriberId) {
    return getSubscriber(subscriberId, RequestOptions.none());
  }

  /**
   * Create or replace a subscriber.
   *
   * <p>{@code PUT /v1/subscribers/{subscriber_id}}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replaceSubscriber(String subscriberId, JsonNode body, RequestOptions options) {
    return requester.json(REPLACE_SUBSCRIBER, List.of(subscriberId), null, body, options);
  }

  /**
   * Create or replace a subscriber.
   *
   * <p>{@code PUT /v1/subscribers/{subscriber_id}}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode replaceSubscriber(String subscriberId, JsonNode body) {
    return replaceSubscriber(subscriberId, body, RequestOptions.none());
  }

  /**
   * Update a subscriber.
   *
   * <p>{@code PATCH /v1/subscribers/{subscriber_id}}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode updateSubscriber(String subscriberId, JsonNode body, RequestOptions options) {
    return requester.json(UPDATE_SUBSCRIBER, List.of(subscriberId), null, body, options);
  }

  /**
   * Update a subscriber.
   *
   * <p>{@code PATCH /v1/subscribers/{subscriber_id}}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode updateSubscriber(String subscriberId, JsonNode body) {
    return updateSubscriber(subscriberId, body, RequestOptions.none());
  }

  /**
   * Request deletion of a subscriber.
   *
   * <p>{@code DELETE /v1/subscribers/{subscriber_id}}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode deleteSubscriber(String subscriberId, RequestOptions options) {
    return requester.json(DELETE_SUBSCRIBER, List.of(subscriberId), null, null, options);
  }

  /**
   * Request deletion of a subscriber.
   *
   * <p>{@code DELETE /v1/subscribers/{subscriber_id}}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @return the response body
   */
  public JsonNode deleteSubscriber(String subscriberId) {
    return deleteSubscriber(subscriberId, RequestOptions.none());
  }

  /**
   * Bulk upsert subscribers.
   *
   * <p>{@code POST /v1/subscribers/bulk}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode bulkUpsertSubscribers(JsonNode body, RequestOptions options) {
    return requester.json(BULK_UPSERT_SUBSCRIBERS, List.of(), null, body, options);
  }

  /**
   * Bulk upsert subscribers.
   *
   * <p>{@code POST /v1/subscribers/bulk}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode bulkUpsertSubscribers(JsonNode body) {
    return bulkUpsertSubscribers(body, RequestOptions.none());
  }

  /**
   * Get subscriber preferences.
   *
   * <p>{@code GET /v1/subscribers/{subscriber_id}/preferences}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getSubscriberPreferences(String subscriberId, RequestOptions options) {
    return requester.json(GET_SUBSCRIBER_PREFERENCES, List.of(subscriberId), null, null, options);
  }

  /**
   * Get subscriber preferences.
   *
   * <p>{@code GET /v1/subscribers/{subscriber_id}/preferences}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @return the response body
   */
  public JsonNode getSubscriberPreferences(String subscriberId) {
    return getSubscriberPreferences(subscriberId, RequestOptions.none());
  }

  /**
   * Update subscriber preferences.
   *
   * <p>{@code PATCH /v1/subscribers/{subscriber_id}/preferences}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode updateSubscriberPreferences(
      String subscriberId, JsonNode body, RequestOptions options) {
    return requester.json(
        UPDATE_SUBSCRIBER_PREFERENCES, List.of(subscriberId), null, body, options);
  }

  /**
   * Update subscriber preferences.
   *
   * <p>{@code PATCH /v1/subscribers/{subscriber_id}/preferences}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode updateSubscriberPreferences(String subscriberId, JsonNode body) {
    return updateSubscriberPreferences(subscriberId, body, RequestOptions.none());
  }

  /**
   * List subscriber consents.
   *
   * <p>{@code GET /v1/subscribers/{subscriber_id}/consents}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listSubscriberConsents(
      String subscriberId, ListSubscriberConsentsParams params, RequestOptions options) {
    return requester.page(LIST_SUBSCRIBER_CONSENTS, List.of(subscriberId), params, options);
  }

  /**
   * List subscriber consents.
   *
   * <p>{@code GET /v1/subscribers/{subscriber_id}/consents}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listSubscriberConsents(String subscriberId) {
    return listSubscriberConsents(subscriberId, null, RequestOptions.none());
  }

  /**
   * List subscriber devices.
   *
   * <p>{@code GET /v1/subscribers/{subscriber_id}/devices}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listSubscriberDevices(
      String subscriberId, ListSubscriberDevicesParams params, RequestOptions options) {
    return requester.page(LIST_SUBSCRIBER_DEVICES, List.of(subscriberId), params, options);
  }

  /**
   * List subscriber devices.
   *
   * <p>{@code GET /v1/subscribers/{subscriber_id}/devices}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listSubscriberDevices(String subscriberId) {
    return listSubscriberDevices(subscriberId, null, RequestOptions.none());
  }

  /**
   * Register a subscriber device.
   *
   * <p>{@code POST /v1/subscribers/{subscriber_id}/devices}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode registerSubscriberDevice(
      String subscriberId, JsonNode body, RequestOptions options) {
    return requester.json(REGISTER_SUBSCRIBER_DEVICE, List.of(subscriberId), null, body, options);
  }

  /**
   * Register a subscriber device.
   *
   * <p>{@code POST /v1/subscribers/{subscriber_id}/devices}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode registerSubscriberDevice(String subscriberId, JsonNode body) {
    return registerSubscriberDevice(subscriberId, body, RequestOptions.none());
  }

  /**
   * Remove a subscriber device.
   *
   * <p>{@code DELETE /v1/subscribers/{subscriber_id}/devices/{device_id}}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param deviceId the {@code device_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode deleteSubscriberDevice(
      String subscriberId, String deviceId, RequestOptions options) {
    return requester.json(
        DELETE_SUBSCRIBER_DEVICE, List.of(subscriberId, deviceId), null, null, options);
  }

  /**
   * Remove a subscriber device.
   *
   * <p>{@code DELETE /v1/subscribers/{subscriber_id}/devices/{device_id}}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param deviceId the {@code device_id} path parameter
   * @return the response body
   */
  public JsonNode deleteSubscriberDevice(String subscriberId, String deviceId) {
    return deleteSubscriberDevice(subscriberId, deviceId, RequestOptions.none());
  }

  /**
   * Remove a device by its token.
   *
   * <p>{@code DELETE /v1/devices/by-token}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode deleteDeviceByToken(JsonNode body, RequestOptions options) {
    return requester.json(DELETE_DEVICE_BY_TOKEN, List.of(), null, body, options);
  }

  /**
   * Remove a device by its token.
   *
   * <p>{@code DELETE /v1/devices/by-token}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode deleteDeviceByToken(JsonNode body) {
    return deleteDeviceByToken(body, RequestOptions.none());
  }

  /**
   * Get the jitter control.
   *
   * <p>{@code GET /v1/timing_settings}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode getTimingSettings(RequestOptions options) {
    return requester.json(GET_TIMING_SETTINGS, List.of(), null, null, options);
  }

  /**
   * Get the jitter control.
   *
   * <p>{@code GET /v1/timing_settings}
   *
   * @return the response body
   */
  public JsonNode getTimingSettings() {
    return getTimingSettings(RequestOptions.none());
  }

  /**
   * Set the jitter control.
   *
   * <p>{@code PUT /v1/timing_settings}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode setTimingSettings(JsonNode body, RequestOptions options) {
    return requester.json(SET_TIMING_SETTINGS, List.of(), null, body, options);
  }

  /**
   * Set the jitter control.
   *
   * <p>{@code PUT /v1/timing_settings}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode setTimingSettings(JsonNode body) {
    return setTimingSettings(body, RequestOptions.none());
  }

  /**
   * Get the allowed browser origins.
   *
   * <p>{@code GET /v1/realtime_origins}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode getRealtimeOrigins(RequestOptions options) {
    return requester.json(GET_REALTIME_ORIGINS, List.of(), null, null, options);
  }

  /**
   * Get the allowed browser origins.
   *
   * <p>{@code GET /v1/realtime_origins}
   *
   * @return the response body
   */
  public JsonNode getRealtimeOrigins() {
    return getRealtimeOrigins(RequestOptions.none());
  }

  /**
   * Set the allowed browser origins.
   *
   * <p>{@code PUT /v1/realtime_origins}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode setRealtimeOrigins(JsonNode body, RequestOptions options) {
    return requester.json(SET_REALTIME_ORIGINS, List.of(), null, body, options);
  }

  /**
   * Set the allowed browser origins.
   *
   * <p>{@code PUT /v1/realtime_origins}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode setRealtimeOrigins(JsonNode body) {
    return setRealtimeOrigins(body, RequestOptions.none());
  }

  /**
   * List routes.
   *
   * <p>{@code GET /v1/routes}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listRoutes(ListRoutesParams params, RequestOptions options) {
    return requester.page(LIST_ROUTES, List.of(), params, options);
  }

  /**
   * List routes.
   *
   * <p>{@code GET /v1/routes}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listRoutes() {
    return listRoutes(null, RequestOptions.none());
  }

  /**
   * Create a route.
   *
   * <p>{@code POST /v1/routes}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createRoute(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_ROUTE, List.of(), null, body, options);
  }

  /**
   * Create a route.
   *
   * <p>{@code POST /v1/routes}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createRoute(JsonNode body) {
    return createRoute(body, RequestOptions.none());
  }

  /**
   * Get a route.
   *
   * <p>{@code GET /v1/routes/{route_key}}
   *
   * @param routeKey the {@code route_key} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getRoute(String routeKey, RequestOptions options) {
    return requester.json(GET_ROUTE, List.of(routeKey), null, null, options);
  }

  /**
   * Get a route.
   *
   * <p>{@code GET /v1/routes/{route_key}}
   *
   * @param routeKey the {@code route_key} path parameter
   * @return the response body
   */
  public JsonNode getRoute(String routeKey) {
    return getRoute(routeKey, RequestOptions.none());
  }

  /**
   * Replace a route.
   *
   * <p>{@code PUT /v1/routes/{route_key}}
   *
   * @param routeKey the {@code route_key} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replaceRoute(String routeKey, JsonNode body, RequestOptions options) {
    return requester.json(REPLACE_ROUTE, List.of(routeKey), null, body, options);
  }

  /**
   * Replace a route.
   *
   * <p>{@code PUT /v1/routes/{route_key}}
   *
   * @param routeKey the {@code route_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode replaceRoute(String routeKey, JsonNode body) {
    return replaceRoute(routeKey, body, RequestOptions.none());
  }

  /**
   * Archive a route.
   *
   * <p>{@code POST /v1/routes/{route_key}/archive}
   *
   * @param routeKey the {@code route_key} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode archiveRoute(String routeKey, RequestOptions options) {
    return requester.json(ARCHIVE_ROUTE, List.of(routeKey), null, null, options);
  }

  /**
   * Archive a route.
   *
   * <p>{@code POST /v1/routes/{route_key}/archive}
   *
   * @param routeKey the {@code route_key} path parameter
   * @return the response body
   */
  public JsonNode archiveRoute(String routeKey) {
    return archiveRoute(routeKey, RequestOptions.none());
  }

  /**
   * List workflows.
   *
   * <p>{@code GET /v1/workflows}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listWorkflows(ListWorkflowsParams params, RequestOptions options) {
    return requester.page(LIST_WORKFLOWS, List.of(), params, options);
  }

  /**
   * List workflows.
   *
   * <p>{@code GET /v1/workflows}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listWorkflows() {
    return listWorkflows(null, RequestOptions.none());
  }

  /**
   * Create a workflow.
   *
   * <p>{@code POST /v1/workflows}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createWorkflow(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_WORKFLOW, List.of(), null, body, options);
  }

  /**
   * Create a workflow.
   *
   * <p>{@code POST /v1/workflows}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createWorkflow(JsonNode body) {
    return createWorkflow(body, RequestOptions.none());
  }

  /**
   * Get a workflow.
   *
   * <p>{@code GET /v1/workflows/{workflow_key}}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getWorkflow(String workflowKey, RequestOptions options) {
    return requester.json(GET_WORKFLOW, List.of(workflowKey), null, null, options);
  }

  /**
   * Get a workflow.
   *
   * <p>{@code GET /v1/workflows/{workflow_key}}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @return the response body
   */
  public JsonNode getWorkflow(String workflowKey) {
    return getWorkflow(workflowKey, RequestOptions.none());
  }

  /**
   * Replace the workflow draft.
   *
   * <p>{@code PUT /v1/workflows/{workflow_key}}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replaceWorkflowDraft(String workflowKey, JsonNode body, RequestOptions options) {
    return requester.json(REPLACE_WORKFLOW_DRAFT, List.of(workflowKey), null, body, options);
  }

  /**
   * Replace the workflow draft.
   *
   * <p>{@code PUT /v1/workflows/{workflow_key}}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode replaceWorkflowDraft(String workflowKey, JsonNode body) {
    return replaceWorkflowDraft(workflowKey, body, RequestOptions.none());
  }

  /**
   * Publish the draft.
   *
   * <p>{@code POST /v1/workflows/{workflow_key}/publish}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode publishWorkflow(String workflowKey, JsonNode body, RequestOptions options) {
    return requester.json(PUBLISH_WORKFLOW, List.of(workflowKey), null, body, options);
  }

  /**
   * Publish the draft.
   *
   * <p>{@code POST /v1/workflows/{workflow_key}/publish}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @return the response body
   */
  public JsonNode publishWorkflow(String workflowKey) {
    return publishWorkflow(workflowKey, null, RequestOptions.none());
  }

  /**
   * Change the workflow manager.
   *
   * <p>{@code POST /v1/workflows/{workflow_key}/manager}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode setWorkflowManager(String workflowKey, JsonNode body, RequestOptions options) {
    return requester.json(SET_WORKFLOW_MANAGER, List.of(workflowKey), null, body, options);
  }

  /**
   * Change the workflow manager.
   *
   * <p>{@code POST /v1/workflows/{workflow_key}/manager}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode setWorkflowManager(String workflowKey, JsonNode body) {
    return setWorkflowManager(workflowKey, body, RequestOptions.none());
  }

  /**
   * List published versions.
   *
   * <p>{@code GET /v1/workflows/{workflow_key}/versions}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listWorkflowVersions(
      String workflowKey, ListWorkflowVersionsParams params, RequestOptions options) {
    return requester.page(LIST_WORKFLOW_VERSIONS, List.of(workflowKey), params, options);
  }

  /**
   * List published versions.
   *
   * <p>{@code GET /v1/workflows/{workflow_key}/versions}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listWorkflowVersions(String workflowKey) {
    return listWorkflowVersions(workflowKey, null, RequestOptions.none());
  }

  /**
   * Get a published version.
   *
   * <p>{@code GET /v1/workflows/{workflow_key}/versions/{version}}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param version the {@code version} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getWorkflowVersion(String workflowKey, String version, RequestOptions options) {
    return requester.json(GET_WORKFLOW_VERSION, List.of(workflowKey, version), null, null, options);
  }

  /**
   * Get a published version.
   *
   * <p>{@code GET /v1/workflows/{workflow_key}/versions/{version}}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param version the {@code version} path parameter
   * @return the response body
   */
  public JsonNode getWorkflowVersion(String workflowKey, String version) {
    return getWorkflowVersion(workflowKey, version, RequestOptions.none());
  }

  /**
   * Export a published version as Mermaid.
   *
   * <p>{@code GET /v1/workflows/{workflow_key}/versions/{version}/mermaid}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param version the {@code version} path parameter
   * @param options the request options
   * @return the response text
   */
  public String getWorkflowVersionMermaid(
      String workflowKey, String version, RequestOptions options) {
    return requester.text(
        GET_WORKFLOW_VERSION_MERMAID, List.of(workflowKey, version), null, null, options);
  }

  /**
   * Export a published version as Mermaid.
   *
   * <p>{@code GET /v1/workflows/{workflow_key}/versions/{version}/mermaid}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param version the {@code version} path parameter
   * @return the response text
   */
  public String getWorkflowVersionMermaid(String workflowKey, String version) {
    return getWorkflowVersionMermaid(workflowKey, version, RequestOptions.none());
  }

  /**
   * Republish an earlier version.
   *
   * <p>{@code POST /v1/workflows/{workflow_key}/versions/{version}/promote}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param version the {@code version} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode promoteWorkflowVersion(
      String workflowKey, String version, RequestOptions options) {
    return requester.json(
        PROMOTE_WORKFLOW_VERSION, List.of(workflowKey, version), null, null, options);
  }

  /**
   * Republish an earlier version.
   *
   * <p>{@code POST /v1/workflows/{workflow_key}/versions/{version}/promote}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param version the {@code version} path parameter
   * @return the response body
   */
  public JsonNode promoteWorkflowVersion(String workflowKey, String version) {
    return promoteWorkflowVersion(workflowKey, version, RequestOptions.none());
  }

  /**
   * Preview a workflow.
   *
   * <p>{@code POST /v1/workflows/{workflow_key}/preview}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode previewWorkflow(String workflowKey, JsonNode body, RequestOptions options) {
    return requester.json(PREVIEW_WORKFLOW, List.of(workflowKey), null, body, options);
  }

  /**
   * Preview a workflow.
   *
   * <p>{@code POST /v1/workflows/{workflow_key}/preview}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode previewWorkflow(String workflowKey, JsonNode body) {
    return previewWorkflow(workflowKey, body, RequestOptions.none());
  }

  /**
   * Test send a workflow.
   *
   * <p>{@code POST /v1/workflows/{workflow_key}/test}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode sendWorkflowTest(String workflowKey, JsonNode body, RequestOptions options) {
    return requester.json(SEND_WORKFLOW_TEST, List.of(workflowKey), null, body, options);
  }

  /**
   * Test send a workflow.
   *
   * <p>{@code POST /v1/workflows/{workflow_key}/test}
   *
   * @param workflowKey the {@code workflow_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode sendWorkflowTest(String workflowKey, JsonNode body) {
    return sendWorkflowTest(workflowKey, body, RequestOptions.none());
  }

  /**
   * List templates.
   *
   * <p>{@code GET /v1/templates}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listTemplates(ListTemplatesParams params, RequestOptions options) {
    return requester.page(LIST_TEMPLATES, List.of(), params, options);
  }

  /**
   * List templates.
   *
   * <p>{@code GET /v1/templates}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listTemplates() {
    return listTemplates(null, RequestOptions.none());
  }

  /**
   * Create a template.
   *
   * <p>{@code POST /v1/templates}
   *
   * @param params the query parameters
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createTemplate(
      CreateTemplateParams params, JsonNode body, RequestOptions options) {
    return requester.json(CREATE_TEMPLATE, List.of(), params, body, options);
  }

  /**
   * Create a template.
   *
   * <p>{@code POST /v1/templates}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createTemplate(JsonNode body) {
    return createTemplate(null, body, RequestOptions.none());
  }

  /**
   * Get a template.
   *
   * <p>{@code GET /v1/templates/{template_key}}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode getTemplate(
      String templateKey, GetTemplateParams params, RequestOptions options) {
    return requester.json(GET_TEMPLATE, List.of(templateKey), params, null, options);
  }

  /**
   * Get a template.
   *
   * <p>{@code GET /v1/templates/{template_key}}
   *
   * @param templateKey the {@code template_key} path parameter
   * @return the response body
   */
  public JsonNode getTemplate(String templateKey) {
    return getTemplate(templateKey, null, RequestOptions.none());
  }

  /**
   * Replace the template draft.
   *
   * <p>{@code PUT /v1/templates/{template_key}}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param params the query parameters
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replaceTemplateDraft(
      String templateKey,
      ReplaceTemplateDraftParams params,
      JsonNode body,
      RequestOptions options) {
    return requester.json(REPLACE_TEMPLATE_DRAFT, List.of(templateKey), params, body, options);
  }

  /**
   * Replace the template draft.
   *
   * <p>{@code PUT /v1/templates/{template_key}}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode replaceTemplateDraft(String templateKey, JsonNode body) {
    return replaceTemplateDraft(templateKey, null, body, RequestOptions.none());
  }

  /**
   * Publish the draft.
   *
   * <p>{@code POST /v1/templates/{template_key}/publish}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param params the query parameters
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode publishTemplate(
      String templateKey, PublishTemplateParams params, JsonNode body, RequestOptions options) {
    return requester.json(PUBLISH_TEMPLATE, List.of(templateKey), params, body, options);
  }

  /**
   * Publish the draft.
   *
   * <p>{@code POST /v1/templates/{template_key}/publish}
   *
   * @param templateKey the {@code template_key} path parameter
   * @return the response body
   */
  public JsonNode publishTemplate(String templateKey) {
    return publishTemplate(templateKey, null, null, RequestOptions.none());
  }

  /**
   * Archive the template.
   *
   * <p>{@code POST /v1/templates/{template_key}/archive}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode archiveTemplate(
      String templateKey, ArchiveTemplateParams params, RequestOptions options) {
    return requester.json(ARCHIVE_TEMPLATE, List.of(templateKey), params, null, options);
  }

  /**
   * Archive the template.
   *
   * <p>{@code POST /v1/templates/{template_key}/archive}
   *
   * @param templateKey the {@code template_key} path parameter
   * @return the response body
   */
  public JsonNode archiveTemplate(String templateKey) {
    return archiveTemplate(templateKey, null, RequestOptions.none());
  }

  /**
   * List template versions.
   *
   * <p>{@code GET /v1/templates/{template_key}/versions}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listTemplateVersions(
      String templateKey, ListTemplateVersionsParams params, RequestOptions options) {
    return requester.page(LIST_TEMPLATE_VERSIONS, List.of(templateKey), params, options);
  }

  /**
   * List template versions.
   *
   * <p>{@code GET /v1/templates/{template_key}/versions}
   *
   * @param templateKey the {@code template_key} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listTemplateVersions(String templateKey) {
    return listTemplateVersions(templateKey, null, RequestOptions.none());
  }

  /**
   * Get a template version.
   *
   * <p>{@code GET /v1/templates/{template_key}/versions/{version}}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param version the {@code version} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode getTemplateVersion(
      String templateKey, String version, GetTemplateVersionParams params, RequestOptions options) {
    return requester.json(
        GET_TEMPLATE_VERSION, List.of(templateKey, version), params, null, options);
  }

  /**
   * Get a template version.
   *
   * <p>{@code GET /v1/templates/{template_key}/versions/{version}}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param version the {@code version} path parameter
   * @return the response body
   */
  public JsonNode getTemplateVersion(String templateKey, String version) {
    return getTemplateVersion(templateKey, version, null, RequestOptions.none());
  }

  /**
   * Roll back to a version.
   *
   * <p>{@code POST /v1/templates/{template_key}/versions/{version}/promote}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param version the {@code version} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode promoteTemplateVersion(
      String templateKey,
      String version,
      PromoteTemplateVersionParams params,
      RequestOptions options) {
    return requester.json(
        PROMOTE_TEMPLATE_VERSION, List.of(templateKey, version), params, null, options);
  }

  /**
   * Roll back to a version.
   *
   * <p>{@code POST /v1/templates/{template_key}/versions/{version}/promote}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param version the {@code version} path parameter
   * @return the response body
   */
  public JsonNode promoteTemplateVersion(String templateKey, String version) {
    return promoteTemplateVersion(templateKey, version, null, RequestOptions.none());
  }

  /**
   * Get the translation matrix.
   *
   * <p>{@code GET /v1/templates/{template_key}/translations}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode getTemplateTranslations(
      String templateKey, GetTemplateTranslationsParams params, RequestOptions options) {
    return requester.json(GET_TEMPLATE_TRANSLATIONS, List.of(templateKey), params, null, options);
  }

  /**
   * Get the translation matrix.
   *
   * <p>{@code GET /v1/templates/{template_key}/translations}
   *
   * @param templateKey the {@code template_key} path parameter
   * @return the response body
   */
  public JsonNode getTemplateTranslations(String templateKey) {
    return getTemplateTranslations(templateKey, null, RequestOptions.none());
  }

  /**
   * Preview a template.
   *
   * <p>{@code POST /v1/templates/{template_key}/preview}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param params the query parameters
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode previewTemplate(
      String templateKey, PreviewTemplateParams params, JsonNode body, RequestOptions options) {
    return requester.json(PREVIEW_TEMPLATE, List.of(templateKey), params, body, options);
  }

  /**
   * Preview a template.
   *
   * <p>{@code POST /v1/templates/{template_key}/preview}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode previewTemplate(String templateKey, JsonNode body) {
    return previewTemplate(templateKey, null, body, RequestOptions.none());
  }

  /**
   * Publish a producer template.
   *
   * <p>{@code PUT /v1/producer_templates/{template_key}}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode publishProducerTemplate(
      String templateKey, JsonNode body, RequestOptions options) {
    return requester.json(PUBLISH_PRODUCER_TEMPLATE, List.of(templateKey), null, body, options);
  }

  /**
   * Publish a producer template.
   *
   * <p>{@code PUT /v1/producer_templates/{template_key}}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode publishProducerTemplate(String templateKey, JsonNode body) {
    return publishProducerTemplate(templateKey, body, RequestOptions.none());
  }

  /**
   * List layouts.
   *
   * <p>{@code GET /v1/layouts}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listLayouts(ListLayoutsParams params, RequestOptions options) {
    return requester.page(LIST_LAYOUTS, List.of(), params, options);
  }

  /**
   * List layouts.
   *
   * <p>{@code GET /v1/layouts}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listLayouts() {
    return listLayouts(null, RequestOptions.none());
  }

  /**
   * Create a layout.
   *
   * <p>{@code POST /v1/layouts}
   *
   * @param params the query parameters
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createLayout(CreateLayoutParams params, JsonNode body, RequestOptions options) {
    return requester.json(CREATE_LAYOUT, List.of(), params, body, options);
  }

  /**
   * Create a layout.
   *
   * <p>{@code POST /v1/layouts}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createLayout(JsonNode body) {
    return createLayout(null, body, RequestOptions.none());
  }

  /**
   * Get a layout.
   *
   * <p>{@code GET /v1/layouts/{layout_key}}
   *
   * @param layoutKey the {@code layout_key} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode getLayout(String layoutKey, GetLayoutParams params, RequestOptions options) {
    return requester.json(GET_LAYOUT, List.of(layoutKey), params, null, options);
  }

  /**
   * Get a layout.
   *
   * <p>{@code GET /v1/layouts/{layout_key}}
   *
   * @param layoutKey the {@code layout_key} path parameter
   * @return the response body
   */
  public JsonNode getLayout(String layoutKey) {
    return getLayout(layoutKey, null, RequestOptions.none());
  }

  /**
   * Replace the layout draft.
   *
   * <p>{@code PUT /v1/layouts/{layout_key}}
   *
   * @param layoutKey the {@code layout_key} path parameter
   * @param params the query parameters
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replaceLayoutDraft(
      String layoutKey, ReplaceLayoutDraftParams params, JsonNode body, RequestOptions options) {
    return requester.json(REPLACE_LAYOUT_DRAFT, List.of(layoutKey), params, body, options);
  }

  /**
   * Replace the layout draft.
   *
   * <p>{@code PUT /v1/layouts/{layout_key}}
   *
   * @param layoutKey the {@code layout_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode replaceLayoutDraft(String layoutKey, JsonNode body) {
    return replaceLayoutDraft(layoutKey, null, body, RequestOptions.none());
  }

  /**
   * Publish the draft.
   *
   * <p>{@code POST /v1/layouts/{layout_key}/publish}
   *
   * @param layoutKey the {@code layout_key} path parameter
   * @param params the query parameters
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode publishLayout(
      String layoutKey, PublishLayoutParams params, JsonNode body, RequestOptions options) {
    return requester.json(PUBLISH_LAYOUT, List.of(layoutKey), params, body, options);
  }

  /**
   * Publish the draft.
   *
   * <p>{@code POST /v1/layouts/{layout_key}/publish}
   *
   * @param layoutKey the {@code layout_key} path parameter
   * @return the response body
   */
  public JsonNode publishLayout(String layoutKey) {
    return publishLayout(layoutKey, null, null, RequestOptions.none());
  }

  /**
   * Archive the layout.
   *
   * <p>{@code POST /v1/layouts/{layout_key}/archive}
   *
   * @param layoutKey the {@code layout_key} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode archiveLayout(
      String layoutKey, ArchiveLayoutParams params, RequestOptions options) {
    return requester.json(ARCHIVE_LAYOUT, List.of(layoutKey), params, null, options);
  }

  /**
   * Archive the layout.
   *
   * <p>{@code POST /v1/layouts/{layout_key}/archive}
   *
   * @param layoutKey the {@code layout_key} path parameter
   * @return the response body
   */
  public JsonNode archiveLayout(String layoutKey) {
    return archiveLayout(layoutKey, null, RequestOptions.none());
  }

  /**
   * List layout versions.
   *
   * <p>{@code GET /v1/layouts/{layout_key}/versions}
   *
   * @param layoutKey the {@code layout_key} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listLayoutVersions(
      String layoutKey, ListLayoutVersionsParams params, RequestOptions options) {
    return requester.page(LIST_LAYOUT_VERSIONS, List.of(layoutKey), params, options);
  }

  /**
   * List layout versions.
   *
   * <p>{@code GET /v1/layouts/{layout_key}/versions}
   *
   * @param layoutKey the {@code layout_key} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listLayoutVersions(String layoutKey) {
    return listLayoutVersions(layoutKey, null, RequestOptions.none());
  }

  /**
   * Get a layout version.
   *
   * <p>{@code GET /v1/layouts/{layout_key}/versions/{version}}
   *
   * @param layoutKey the {@code layout_key} path parameter
   * @param version the {@code version} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode getLayoutVersion(
      String layoutKey, String version, GetLayoutVersionParams params, RequestOptions options) {
    return requester.json(GET_LAYOUT_VERSION, List.of(layoutKey, version), params, null, options);
  }

  /**
   * Get a layout version.
   *
   * <p>{@code GET /v1/layouts/{layout_key}/versions/{version}}
   *
   * @param layoutKey the {@code layout_key} path parameter
   * @param version the {@code version} path parameter
   * @return the response body
   */
  public JsonNode getLayoutVersion(String layoutKey, String version) {
    return getLayoutVersion(layoutKey, version, null, RequestOptions.none());
  }

  /**
   * Roll back to a version.
   *
   * <p>{@code POST /v1/layouts/{layout_key}/versions/{version}/promote}
   *
   * @param layoutKey the {@code layout_key} path parameter
   * @param version the {@code version} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode promoteLayoutVersion(
      String layoutKey, String version, PromoteLayoutVersionParams params, RequestOptions options) {
    return requester.json(
        PROMOTE_LAYOUT_VERSION, List.of(layoutKey, version), params, null, options);
  }

  /**
   * Roll back to a version.
   *
   * <p>{@code POST /v1/layouts/{layout_key}/versions/{version}/promote}
   *
   * @param layoutKey the {@code layout_key} path parameter
   * @param version the {@code version} path parameter
   * @return the response body
   */
  public JsonNode promoteLayoutVersion(String layoutKey, String version) {
    return promoteLayoutVersion(layoutKey, version, null, RequestOptions.none());
  }

  /**
   * List partials.
   *
   * <p>{@code GET /v1/partials}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listPartials(ListPartialsParams params, RequestOptions options) {
    return requester.page(LIST_PARTIALS, List.of(), params, options);
  }

  /**
   * List partials.
   *
   * <p>{@code GET /v1/partials}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listPartials() {
    return listPartials(null, RequestOptions.none());
  }

  /**
   * Create a partial.
   *
   * <p>{@code POST /v1/partials}
   *
   * @param params the query parameters
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createPartial(CreatePartialParams params, JsonNode body, RequestOptions options) {
    return requester.json(CREATE_PARTIAL, List.of(), params, body, options);
  }

  /**
   * Create a partial.
   *
   * <p>{@code POST /v1/partials}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createPartial(JsonNode body) {
    return createPartial(null, body, RequestOptions.none());
  }

  /**
   * Get a partial.
   *
   * <p>{@code GET /v1/partials/{partial_key}}
   *
   * @param partialKey the {@code partial_key} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode getPartial(String partialKey, GetPartialParams params, RequestOptions options) {
    return requester.json(GET_PARTIAL, List.of(partialKey), params, null, options);
  }

  /**
   * Get a partial.
   *
   * <p>{@code GET /v1/partials/{partial_key}}
   *
   * @param partialKey the {@code partial_key} path parameter
   * @return the response body
   */
  public JsonNode getPartial(String partialKey) {
    return getPartial(partialKey, null, RequestOptions.none());
  }

  /**
   * Replace the partial draft.
   *
   * <p>{@code PUT /v1/partials/{partial_key}}
   *
   * @param partialKey the {@code partial_key} path parameter
   * @param params the query parameters
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replacePartialDraft(
      String partialKey, ReplacePartialDraftParams params, JsonNode body, RequestOptions options) {
    return requester.json(REPLACE_PARTIAL_DRAFT, List.of(partialKey), params, body, options);
  }

  /**
   * Replace the partial draft.
   *
   * <p>{@code PUT /v1/partials/{partial_key}}
   *
   * @param partialKey the {@code partial_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode replacePartialDraft(String partialKey, JsonNode body) {
    return replacePartialDraft(partialKey, null, body, RequestOptions.none());
  }

  /**
   * Publish the draft.
   *
   * <p>{@code POST /v1/partials/{partial_key}/publish}
   *
   * @param partialKey the {@code partial_key} path parameter
   * @param params the query parameters
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode publishPartial(
      String partialKey, PublishPartialParams params, JsonNode body, RequestOptions options) {
    return requester.json(PUBLISH_PARTIAL, List.of(partialKey), params, body, options);
  }

  /**
   * Publish the draft.
   *
   * <p>{@code POST /v1/partials/{partial_key}/publish}
   *
   * @param partialKey the {@code partial_key} path parameter
   * @return the response body
   */
  public JsonNode publishPartial(String partialKey) {
    return publishPartial(partialKey, null, null, RequestOptions.none());
  }

  /**
   * Archive the partial.
   *
   * <p>{@code POST /v1/partials/{partial_key}/archive}
   *
   * @param partialKey the {@code partial_key} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode archivePartial(
      String partialKey, ArchivePartialParams params, RequestOptions options) {
    return requester.json(ARCHIVE_PARTIAL, List.of(partialKey), params, null, options);
  }

  /**
   * Archive the partial.
   *
   * <p>{@code POST /v1/partials/{partial_key}/archive}
   *
   * @param partialKey the {@code partial_key} path parameter
   * @return the response body
   */
  public JsonNode archivePartial(String partialKey) {
    return archivePartial(partialKey, null, RequestOptions.none());
  }

  /**
   * List partial versions.
   *
   * <p>{@code GET /v1/partials/{partial_key}/versions}
   *
   * @param partialKey the {@code partial_key} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listPartialVersions(
      String partialKey, ListPartialVersionsParams params, RequestOptions options) {
    return requester.page(LIST_PARTIAL_VERSIONS, List.of(partialKey), params, options);
  }

  /**
   * List partial versions.
   *
   * <p>{@code GET /v1/partials/{partial_key}/versions}
   *
   * @param partialKey the {@code partial_key} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listPartialVersions(String partialKey) {
    return listPartialVersions(partialKey, null, RequestOptions.none());
  }

  /**
   * Get a partial version.
   *
   * <p>{@code GET /v1/partials/{partial_key}/versions/{version}}
   *
   * @param partialKey the {@code partial_key} path parameter
   * @param version the {@code version} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode getPartialVersion(
      String partialKey, String version, GetPartialVersionParams params, RequestOptions options) {
    return requester.json(GET_PARTIAL_VERSION, List.of(partialKey, version), params, null, options);
  }

  /**
   * Get a partial version.
   *
   * <p>{@code GET /v1/partials/{partial_key}/versions/{version}}
   *
   * @param partialKey the {@code partial_key} path parameter
   * @param version the {@code version} path parameter
   * @return the response body
   */
  public JsonNode getPartialVersion(String partialKey, String version) {
    return getPartialVersion(partialKey, version, null, RequestOptions.none());
  }

  /**
   * Roll back to a version.
   *
   * <p>{@code POST /v1/partials/{partial_key}/versions/{version}/promote}
   *
   * @param partialKey the {@code partial_key} path parameter
   * @param version the {@code version} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode promotePartialVersion(
      String partialKey,
      String version,
      PromotePartialVersionParams params,
      RequestOptions options) {
    return requester.json(
        PROMOTE_PARTIAL_VERSION, List.of(partialKey, version), params, null, options);
  }

  /**
   * Roll back to a version.
   *
   * <p>{@code POST /v1/partials/{partial_key}/versions/{version}/promote}
   *
   * @param partialKey the {@code partial_key} path parameter
   * @param version the {@code version} path parameter
   * @return the response body
   */
  public JsonNode promotePartialVersion(String partialKey, String version) {
    return promotePartialVersion(partialKey, version, null, RequestOptions.none());
  }

  /**
   * Get the brand settings.
   *
   * <p>{@code GET /v1/brand}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode getBrand(GetBrandParams params, RequestOptions options) {
    return requester.json(GET_BRAND, List.of(), params, null, options);
  }

  /**
   * Get the brand settings.
   *
   * <p>{@code GET /v1/brand}
   *
   * @return the response body
   */
  public JsonNode getBrand() {
    return getBrand(null, RequestOptions.none());
  }

  /**
   * Update the brand settings.
   *
   * <p>{@code PATCH /v1/brand}
   *
   * @param params the query parameters
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode updateBrand(UpdateBrandParams params, JsonNode body, RequestOptions options) {
    return requester.json(UPDATE_BRAND, List.of(), params, body, options);
  }

  /**
   * Update the brand settings.
   *
   * <p>{@code PATCH /v1/brand}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode updateBrand(JsonNode body) {
    return updateBrand(null, body, RequestOptions.none());
  }

  /**
   * Get the compliance settings.
   *
   * <p>{@code GET /v1/compliance_settings}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode getComplianceSettings(RequestOptions options) {
    return requester.json(GET_COMPLIANCE_SETTINGS, List.of(), null, null, options);
  }

  /**
   * Get the compliance settings.
   *
   * <p>{@code GET /v1/compliance_settings}
   *
   * @return the response body
   */
  public JsonNode getComplianceSettings() {
    return getComplianceSettings(RequestOptions.none());
  }

  /**
   * Replace the tenant compliance settings.
   *
   * <p>{@code PUT /v1/compliance_settings}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replaceComplianceSettings(JsonNode body, RequestOptions options) {
    return requester.json(REPLACE_COMPLIANCE_SETTINGS, List.of(), null, body, options);
  }

  /**
   * Replace the tenant compliance settings.
   *
   * <p>{@code PUT /v1/compliance_settings}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode replaceComplianceSettings(JsonNode body) {
    return replaceComplianceSettings(body, RequestOptions.none());
  }

  /**
   * Get the DLR windows.
   *
   * <p>{@code GET /v1/delivery_windows}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode getDeliveryWindows(RequestOptions options) {
    return requester.json(GET_DELIVERY_WINDOWS, List.of(), null, null, options);
  }

  /**
   * Get the DLR windows.
   *
   * <p>{@code GET /v1/delivery_windows}
   *
   * @return the response body
   */
  public JsonNode getDeliveryWindows() {
    return getDeliveryWindows(RequestOptions.none());
  }

  /**
   * Replace the tenant DLR windows.
   *
   * <p>{@code PUT /v1/delivery_windows}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replaceDeliveryWindows(JsonNode body, RequestOptions options) {
    return requester.json(REPLACE_DELIVERY_WINDOWS, List.of(), null, body, options);
  }

  /**
   * Replace the tenant DLR windows.
   *
   * <p>{@code PUT /v1/delivery_windows}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode replaceDeliveryWindows(JsonNode body) {
    return replaceDeliveryWindows(body, RequestOptions.none());
  }

  /**
   * List CloudEvents type mappings.
   *
   * <p>{@code GET /v1/event_type_mappings}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listEventTypeMappings(ListEventTypeMappingsParams params, RequestOptions options) {
    return requester.page(LIST_EVENT_TYPE_MAPPINGS, List.of(), params, options);
  }

  /**
   * List CloudEvents type mappings.
   *
   * <p>{@code GET /v1/event_type_mappings}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listEventTypeMappings() {
    return listEventTypeMappings(null, RequestOptions.none());
  }

  /**
   * Create a CloudEvents type mapping.
   *
   * <p>{@code POST /v1/event_type_mappings}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createEventTypeMapping(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_EVENT_TYPE_MAPPING, List.of(), null, body, options);
  }

  /**
   * Create a CloudEvents type mapping.
   *
   * <p>{@code POST /v1/event_type_mappings}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createEventTypeMapping(JsonNode body) {
    return createEventTypeMapping(body, RequestOptions.none());
  }

  /**
   * Get a CloudEvents type mapping.
   *
   * <p>{@code GET /v1/event_type_mappings/{mapping_id}}
   *
   * @param mappingId the {@code mapping_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getEventTypeMapping(String mappingId, RequestOptions options) {
    return requester.json(GET_EVENT_TYPE_MAPPING, List.of(mappingId), null, null, options);
  }

  /**
   * Get a CloudEvents type mapping.
   *
   * <p>{@code GET /v1/event_type_mappings/{mapping_id}}
   *
   * @param mappingId the {@code mapping_id} path parameter
   * @return the response body
   */
  public JsonNode getEventTypeMapping(String mappingId) {
    return getEventTypeMapping(mappingId, RequestOptions.none());
  }

  /**
   * Replace a CloudEvents type mapping.
   *
   * <p>{@code PUT /v1/event_type_mappings/{mapping_id}}
   *
   * @param mappingId the {@code mapping_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replaceEventTypeMapping(String mappingId, JsonNode body, RequestOptions options) {
    return requester.json(REPLACE_EVENT_TYPE_MAPPING, List.of(mappingId), null, body, options);
  }

  /**
   * Replace a CloudEvents type mapping.
   *
   * <p>{@code PUT /v1/event_type_mappings/{mapping_id}}
   *
   * @param mappingId the {@code mapping_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode replaceEventTypeMapping(String mappingId, JsonNode body) {
    return replaceEventTypeMapping(mappingId, body, RequestOptions.none());
  }

  /**
   * Archive a CloudEvents type mapping.
   *
   * <p>{@code POST /v1/event_type_mappings/{mapping_id}/archive}
   *
   * @param mappingId the {@code mapping_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode archiveEventTypeMapping(String mappingId, RequestOptions options) {
    return requester.json(ARCHIVE_EVENT_TYPE_MAPPING, List.of(mappingId), null, null, options);
  }

  /**
   * Archive a CloudEvents type mapping.
   *
   * <p>{@code POST /v1/event_type_mappings/{mapping_id}/archive}
   *
   * @param mappingId the {@code mapping_id} path parameter
   * @return the response body
   */
  public JsonNode archiveEventTypeMapping(String mappingId) {
    return archiveEventTypeMapping(mappingId, RequestOptions.none());
  }

  /**
   * List categories.
   *
   * <p>{@code GET /v1/categories}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listCategories(ListCategoriesParams params, RequestOptions options) {
    return requester.page(LIST_CATEGORIES, List.of(), params, options);
  }

  /**
   * List categories.
   *
   * <p>{@code GET /v1/categories}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listCategories() {
    return listCategories(null, RequestOptions.none());
  }

  /**
   * Create a category.
   *
   * <p>{@code POST /v1/categories}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createCategory(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_CATEGORY, List.of(), null, body, options);
  }

  /**
   * Create a category.
   *
   * <p>{@code POST /v1/categories}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createCategory(JsonNode body) {
    return createCategory(body, RequestOptions.none());
  }

  /**
   * Get a category.
   *
   * <p>{@code GET /v1/categories/{category_key}}
   *
   * @param categoryKey the {@code category_key} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getCategory(String categoryKey, RequestOptions options) {
    return requester.json(GET_CATEGORY, List.of(categoryKey), null, null, options);
  }

  /**
   * Get a category.
   *
   * <p>{@code GET /v1/categories/{category_key}}
   *
   * @param categoryKey the {@code category_key} path parameter
   * @return the response body
   */
  public JsonNode getCategory(String categoryKey) {
    return getCategory(categoryKey, RequestOptions.none());
  }

  /**
   * Update a category.
   *
   * <p>{@code PATCH /v1/categories/{category_key}}
   *
   * @param categoryKey the {@code category_key} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode updateCategory(String categoryKey, JsonNode body, RequestOptions options) {
    return requester.json(UPDATE_CATEGORY, List.of(categoryKey), null, body, options);
  }

  /**
   * Update a category.
   *
   * <p>{@code PATCH /v1/categories/{category_key}}
   *
   * @param categoryKey the {@code category_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode updateCategory(String categoryKey, JsonNode body) {
    return updateCategory(categoryKey, body, RequestOptions.none());
  }

  /**
   * Archive a category.
   *
   * <p>{@code POST /v1/categories/{category_key}/archive}
   *
   * @param categoryKey the {@code category_key} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode archiveCategory(String categoryKey, RequestOptions options) {
    return requester.json(ARCHIVE_CATEGORY, List.of(categoryKey), null, null, options);
  }

  /**
   * Archive a category.
   *
   * <p>{@code POST /v1/categories/{category_key}/archive}
   *
   * @param categoryKey the {@code category_key} path parameter
   * @return the response body
   */
  public JsonNode archiveCategory(String categoryKey) {
    return archiveCategory(categoryKey, RequestOptions.none());
  }

  /**
   * Get a subtenant setting of a category.
   *
   * <p>{@code GET /v1/categories/{category_key}/subtenants/{subtenant_id}}
   *
   * @param categoryKey the {@code category_key} path parameter
   * @param subtenantId the {@code subtenant_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getCategorySubtenantSetting(
      String categoryKey, String subtenantId, RequestOptions options) {
    return requester.json(
        GET_CATEGORY_SUBTENANT_SETTING, List.of(categoryKey, subtenantId), null, null, options);
  }

  /**
   * Get a subtenant setting of a category.
   *
   * <p>{@code GET /v1/categories/{category_key}/subtenants/{subtenant_id}}
   *
   * @param categoryKey the {@code category_key} path parameter
   * @param subtenantId the {@code subtenant_id} path parameter
   * @return the response body
   */
  public JsonNode getCategorySubtenantSetting(String categoryKey, String subtenantId) {
    return getCategorySubtenantSetting(categoryKey, subtenantId, RequestOptions.none());
  }

  /**
   * Set a subtenant setting of a category.
   *
   * <p>{@code PUT /v1/categories/{category_key}/subtenants/{subtenant_id}}
   *
   * @param categoryKey the {@code category_key} path parameter
   * @param subtenantId the {@code subtenant_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replaceCategorySubtenantSetting(
      String categoryKey, String subtenantId, JsonNode body, RequestOptions options) {
    return requester.json(
        REPLACE_CATEGORY_SUBTENANT_SETTING, List.of(categoryKey, subtenantId), null, body, options);
  }

  /**
   * Set a subtenant setting of a category.
   *
   * <p>{@code PUT /v1/categories/{category_key}/subtenants/{subtenant_id}}
   *
   * @param categoryKey the {@code category_key} path parameter
   * @param subtenantId the {@code subtenant_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode replaceCategorySubtenantSetting(
      String categoryKey, String subtenantId, JsonNode body) {
    return replaceCategorySubtenantSetting(categoryKey, subtenantId, body, RequestOptions.none());
  }

  /**
   * Get the e-mail tracking of a category.
   *
   * <p>{@code GET /v1/categories/{category_key}/email_tracking}
   *
   * @param categoryKey the {@code category_key} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getCategoryEmailTracking(String categoryKey, RequestOptions options) {
    return requester.json(GET_CATEGORY_EMAIL_TRACKING, List.of(categoryKey), null, null, options);
  }

  /**
   * Get the e-mail tracking of a category.
   *
   * <p>{@code GET /v1/categories/{category_key}/email_tracking}
   *
   * @param categoryKey the {@code category_key} path parameter
   * @return the response body
   */
  public JsonNode getCategoryEmailTracking(String categoryKey) {
    return getCategoryEmailTracking(categoryKey, RequestOptions.none());
  }

  /**
   * Set the e-mail tracking of a category.
   *
   * <p>{@code PUT /v1/categories/{category_key}/email_tracking}
   *
   * @param categoryKey the {@code category_key} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replaceCategoryEmailTracking(
      String categoryKey, JsonNode body, RequestOptions options) {
    return requester.json(
        REPLACE_CATEGORY_EMAIL_TRACKING, List.of(categoryKey), null, body, options);
  }

  /**
   * Set the e-mail tracking of a category.
   *
   * <p>{@code PUT /v1/categories/{category_key}/email_tracking}
   *
   * @param categoryKey the {@code category_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode replaceCategoryEmailTracking(String categoryKey, JsonNode body) {
    return replaceCategoryEmailTracking(categoryKey, body, RequestOptions.none());
  }

  /**
   * Get the e-mail tracking of a template.
   *
   * <p>{@code GET /v1/templates/{template_key}/email_tracking}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getTemplateEmailTracking(String templateKey, RequestOptions options) {
    return requester.json(GET_TEMPLATE_EMAIL_TRACKING, List.of(templateKey), null, null, options);
  }

  /**
   * Get the e-mail tracking of a template.
   *
   * <p>{@code GET /v1/templates/{template_key}/email_tracking}
   *
   * @param templateKey the {@code template_key} path parameter
   * @return the response body
   */
  public JsonNode getTemplateEmailTracking(String templateKey) {
    return getTemplateEmailTracking(templateKey, RequestOptions.none());
  }

  /**
   * Set the e-mail tracking of a template.
   *
   * <p>{@code PUT /v1/templates/{template_key}/email_tracking}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replaceTemplateEmailTracking(
      String templateKey, JsonNode body, RequestOptions options) {
    return requester.json(
        REPLACE_TEMPLATE_EMAIL_TRACKING, List.of(templateKey), null, body, options);
  }

  /**
   * Set the e-mail tracking of a template.
   *
   * <p>{@code PUT /v1/templates/{template_key}/email_tracking}
   *
   * @param templateKey the {@code template_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode replaceTemplateEmailTracking(String templateKey, JsonNode body) {
    return replaceTemplateEmailTracking(templateKey, body, RequestOptions.none());
  }

  /**
   * List suppressions.
   *
   * <p>{@code GET /v1/suppressions}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listSuppressions(ListSuppressionsParams params, RequestOptions options) {
    return requester.page(LIST_SUPPRESSIONS, List.of(), params, options);
  }

  /**
   * List suppressions.
   *
   * <p>{@code GET /v1/suppressions}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listSuppressions() {
    return listSuppressions(null, RequestOptions.none());
  }

  /**
   * Add a suppression.
   *
   * <p>{@code POST /v1/suppressions}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createSuppression(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_SUPPRESSION, List.of(), null, body, options);
  }

  /**
   * Add a suppression.
   *
   * <p>{@code POST /v1/suppressions}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createSuppression(JsonNode body) {
    return createSuppression(body, RequestOptions.none());
  }

  /**
   * Lift a suppression.
   *
   * <p>{@code POST /v1/suppressions/{suppression_id}/lift}
   *
   * @param suppressionId the {@code suppression_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode liftSuppression(String suppressionId, JsonNode body, RequestOptions options) {
    return requester.json(LIFT_SUPPRESSION, List.of(suppressionId), null, body, options);
  }

  /**
   * Lift a suppression.
   *
   * <p>{@code POST /v1/suppressions/{suppression_id}/lift}
   *
   * @param suppressionId the {@code suppression_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode liftSuppression(String suppressionId, JsonNode body) {
    return liftSuppression(suppressionId, body, RequestOptions.none());
  }

  /**
   * Get the SMS destination policy.
   *
   * <p>{@code GET /v1/sms_destination_policy}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode getSmsDestinationPolicy(RequestOptions options) {
    return requester.json(GET_SMS_DESTINATION_POLICY, List.of(), null, null, options);
  }

  /**
   * Get the SMS destination policy.
   *
   * <p>{@code GET /v1/sms_destination_policy}
   *
   * @return the response body
   */
  public JsonNode getSmsDestinationPolicy() {
    return getSmsDestinationPolicy(RequestOptions.none());
  }

  /**
   * Set the SMS destination policy.
   *
   * <p>{@code PUT /v1/sms_destination_policy}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode setSmsDestinationPolicy(JsonNode body, RequestOptions options) {
    return requester.json(SET_SMS_DESTINATION_POLICY, List.of(), null, body, options);
  }

  /**
   * Set the SMS destination policy.
   *
   * <p>{@code PUT /v1/sms_destination_policy}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode setSmsDestinationPolicy(JsonNode body) {
    return setSmsDestinationPolicy(body, RequestOptions.none());
  }

  /**
   * List SMS destination stops.
   *
   * <p>{@code GET /v1/sms_destination_stops}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listSmsDestinationStops(
      ListSmsDestinationStopsParams params, RequestOptions options) {
    return requester.page(LIST_SMS_DESTINATION_STOPS, List.of(), params, options);
  }

  /**
   * List SMS destination stops.
   *
   * <p>{@code GET /v1/sms_destination_stops}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listSmsDestinationStops() {
    return listSmsDestinationStops(null, RequestOptions.none());
  }

  /**
   * Lift an SMS destination stop.
   *
   * <p>{@code POST /v1/sms_destination_stops/{sms_destination_stop_id}/lift}
   *
   * @param smsDestinationStopId the {@code sms_destination_stop_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode liftSmsDestinationStop(
      String smsDestinationStopId, JsonNode body, RequestOptions options) {
    return requester.json(
        LIFT_SMS_DESTINATION_STOP, List.of(smsDestinationStopId), null, body, options);
  }

  /**
   * Lift an SMS destination stop.
   *
   * <p>{@code POST /v1/sms_destination_stops/{sms_destination_stop_id}/lift}
   *
   * @param smsDestinationStopId the {@code sms_destination_stop_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode liftSmsDestinationStop(String smsDestinationStopId, JsonNode body) {
    return liftSmsDestinationStop(smsDestinationStopId, body, RequestOptions.none());
  }

  /**
   * List test recipients.
   *
   * <p>{@code GET /v1/test_recipients}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode listTestRecipients(RequestOptions options) {
    return requester.json(LIST_TEST_RECIPIENTS, List.of(), null, null, options);
  }

  /**
   * List test recipients.
   *
   * <p>{@code GET /v1/test_recipients}
   *
   * @return the response body
   */
  public JsonNode listTestRecipients() {
    return listTestRecipients(RequestOptions.none());
  }

  /**
   * Add a test recipient.
   *
   * <p>{@code POST /v1/test_recipients}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createTestRecipient(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_TEST_RECIPIENT, List.of(), null, body, options);
  }

  /**
   * Add a test recipient.
   *
   * <p>{@code POST /v1/test_recipients}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createTestRecipient(JsonNode body) {
    return createTestRecipient(body, RequestOptions.none());
  }

  /**
   * Remove a test recipient.
   *
   * <p>{@code POST /v1/test_recipients/{test_recipient_id}/remove}
   *
   * @param testRecipientId the {@code test_recipient_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode removeTestRecipient(String testRecipientId, RequestOptions options) {
    return requester.json(REMOVE_TEST_RECIPIENT, List.of(testRecipientId), null, null, options);
  }

  /**
   * Remove a test recipient.
   *
   * <p>{@code POST /v1/test_recipients/{test_recipient_id}/remove}
   *
   * @param testRecipientId the {@code test_recipient_id} path parameter
   * @return the response body
   */
  public JsonNode removeTestRecipient(String testRecipientId) {
    return removeTestRecipient(testRecipientId, RequestOptions.none());
  }

  /**
   * Publish an inbox announcement.
   *
   * <p>{@code POST /v1/inbox/announcements}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createInboxAnnouncement(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_INBOX_ANNOUNCEMENT, List.of(), null, body, options);
  }

  /**
   * Publish an inbox announcement.
   *
   * <p>{@code POST /v1/inbox/announcements}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createInboxAnnouncement(JsonNode body) {
    return createInboxAnnouncement(body, RequestOptions.none());
  }

  /**
   * Get an inbox announcement.
   *
   * <p>{@code GET /v1/inbox/announcements/{announcement_id}}
   *
   * @param announcementId the {@code announcement_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getInboxAnnouncement(String announcementId, RequestOptions options) {
    return requester.json(GET_INBOX_ANNOUNCEMENT, List.of(announcementId), null, null, options);
  }

  /**
   * Get an inbox announcement.
   *
   * <p>{@code GET /v1/inbox/announcements/{announcement_id}}
   *
   * @param announcementId the {@code announcement_id} path parameter
   * @return the response body
   */
  public JsonNode getInboxAnnouncement(String announcementId) {
    return getInboxAnnouncement(announcementId, RequestOptions.none());
  }

  /**
   * Retract an inbox announcement.
   *
   * <p>{@code POST /v1/inbox/announcements/{announcement_id}/retract}
   *
   * @param announcementId the {@code announcement_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode retractInboxAnnouncement(String announcementId, RequestOptions options) {
    return requester.json(RETRACT_INBOX_ANNOUNCEMENT, List.of(announcementId), null, null, options);
  }

  /**
   * Retract an inbox announcement.
   *
   * <p>{@code POST /v1/inbox/announcements/{announcement_id}/retract}
   *
   * @param announcementId the {@code announcement_id} path parameter
   * @return the response body
   */
  public JsonNode retractInboxAnnouncement(String announcementId) {
    return retractInboxAnnouncement(announcementId, RequestOptions.none());
  }

  /**
   * List topics.
   *
   * <p>{@code GET /v1/topics}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listTopics(ListTopicsParams params, RequestOptions options) {
    return requester.page(LIST_TOPICS, List.of(), params, options);
  }

  /**
   * List topics.
   *
   * <p>{@code GET /v1/topics}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listTopics() {
    return listTopics(null, RequestOptions.none());
  }

  /**
   * Create a topic.
   *
   * <p>{@code POST /v1/topics}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createTopic(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_TOPIC, List.of(), null, body, options);
  }

  /**
   * Create a topic.
   *
   * <p>{@code POST /v1/topics}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createTopic(JsonNode body) {
    return createTopic(body, RequestOptions.none());
  }

  /**
   * Get a topic.
   *
   * <p>{@code GET /v1/topics/{topic_key}}
   *
   * @param topicKey the {@code topic_key} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getTopic(String topicKey, RequestOptions options) {
    return requester.json(GET_TOPIC, List.of(topicKey), null, null, options);
  }

  /**
   * Get a topic.
   *
   * <p>{@code GET /v1/topics/{topic_key}}
   *
   * @param topicKey the {@code topic_key} path parameter
   * @return the response body
   */
  public JsonNode getTopic(String topicKey) {
    return getTopic(topicKey, RequestOptions.none());
  }

  /**
   * Archive a topic.
   *
   * <p>{@code POST /v1/topics/{topic_key}/archive}
   *
   * @param topicKey the {@code topic_key} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode archiveTopic(String topicKey, RequestOptions options) {
    return requester.json(ARCHIVE_TOPIC, List.of(topicKey), null, null, options);
  }

  /**
   * Archive a topic.
   *
   * <p>{@code POST /v1/topics/{topic_key}/archive}
   *
   * @param topicKey the {@code topic_key} path parameter
   * @return the response body
   */
  public JsonNode archiveTopic(String topicKey) {
    return archiveTopic(topicKey, RequestOptions.none());
  }

  /**
   * List the subscriptions of a topic.
   *
   * <p>{@code GET /v1/topics/{topic_key}/subscriptions}
   *
   * @param topicKey the {@code topic_key} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listTopicSubscriptions(
      String topicKey, ListTopicSubscriptionsParams params, RequestOptions options) {
    return requester.page(LIST_TOPIC_SUBSCRIPTIONS, List.of(topicKey), params, options);
  }

  /**
   * List the subscriptions of a topic.
   *
   * <p>{@code GET /v1/topics/{topic_key}/subscriptions}
   *
   * @param topicKey the {@code topic_key} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listTopicSubscriptions(String topicKey) {
    return listTopicSubscriptions(topicKey, null, RequestOptions.none());
  }

  /**
   * Subscribe subscribers to a topic.
   *
   * <p>{@code POST /v1/topics/{topic_key}/subscriptions}
   *
   * @param topicKey the {@code topic_key} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode addTopicSubscriptions(String topicKey, JsonNode body, RequestOptions options) {
    return requester.json(ADD_TOPIC_SUBSCRIPTIONS, List.of(topicKey), null, body, options);
  }

  /**
   * Subscribe subscribers to a topic.
   *
   * <p>{@code POST /v1/topics/{topic_key}/subscriptions}
   *
   * @param topicKey the {@code topic_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode addTopicSubscriptions(String topicKey, JsonNode body) {
    return addTopicSubscriptions(topicKey, body, RequestOptions.none());
  }

  /**
   * Unsubscribe subscribers from a topic.
   *
   * <p>{@code POST /v1/topics/{topic_key}/subscriptions/remove}
   *
   * @param topicKey the {@code topic_key} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode removeTopicSubscriptions(String topicKey, JsonNode body, RequestOptions options) {
    return requester.json(REMOVE_TOPIC_SUBSCRIPTIONS, List.of(topicKey), null, body, options);
  }

  /**
   * Unsubscribe subscribers from a topic.
   *
   * <p>{@code POST /v1/topics/{topic_key}/subscriptions/remove}
   *
   * @param topicKey the {@code topic_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode removeTopicSubscriptions(String topicKey, JsonNode body) {
    return removeTopicSubscriptions(topicKey, body, RequestOptions.none());
  }

  /**
   * List the topics a subscriber is subscribed to.
   *
   * <p>{@code GET /v1/subscribers/{subscriber_id}/subscriptions}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listSubscriberSubscriptions(
      String subscriberId, ListSubscriberSubscriptionsParams params, RequestOptions options) {
    return requester.page(LIST_SUBSCRIBER_SUBSCRIPTIONS, List.of(subscriberId), params, options);
  }

  /**
   * List the topics a subscriber is subscribed to.
   *
   * <p>{@code GET /v1/subscribers/{subscriber_id}/subscriptions}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listSubscriberSubscriptions(String subscriberId) {
    return listSubscriberSubscriptions(subscriberId, null, RequestOptions.none());
  }

  /**
   * List kill switches.
   *
   * <p>{@code GET /v1/kill_switches}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listKillSwitches(ListKillSwitchesParams params, RequestOptions options) {
    return requester.page(LIST_KILL_SWITCHES, List.of(), params, options);
  }

  /**
   * List kill switches.
   *
   * <p>{@code GET /v1/kill_switches}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listKillSwitches() {
    return listKillSwitches(null, RequestOptions.none());
  }

  /**
   * Engage a kill switch.
   *
   * <p>{@code POST /v1/kill_switches}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode engageKillSwitch(JsonNode body, RequestOptions options) {
    return requester.json(ENGAGE_KILL_SWITCH, List.of(), null, body, options);
  }

  /**
   * Engage a kill switch.
   *
   * <p>{@code POST /v1/kill_switches}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode engageKillSwitch(JsonNode body) {
    return engageKillSwitch(body, RequestOptions.none());
  }

  /**
   * Get a kill switch.
   *
   * <p>{@code GET /v1/kill_switches/{kill_switch_id}}
   *
   * @param killSwitchId the {@code kill_switch_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getKillSwitch(String killSwitchId, RequestOptions options) {
    return requester.json(GET_KILL_SWITCH, List.of(killSwitchId), null, null, options);
  }

  /**
   * Get a kill switch.
   *
   * <p>{@code GET /v1/kill_switches/{kill_switch_id}}
   *
   * @param killSwitchId the {@code kill_switch_id} path parameter
   * @return the response body
   */
  public JsonNode getKillSwitch(String killSwitchId) {
    return getKillSwitch(killSwitchId, RequestOptions.none());
  }

  /**
   * Replace the state of a kill switch.
   *
   * <p>{@code POST /v1/kill_switches/{kill_switch_id}/replace}
   *
   * @param killSwitchId the {@code kill_switch_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replaceKillSwitch(String killSwitchId, JsonNode body, RequestOptions options) {
    return requester.json(REPLACE_KILL_SWITCH, List.of(killSwitchId), null, body, options);
  }

  /**
   * Replace the state of a kill switch.
   *
   * <p>{@code POST /v1/kill_switches/{kill_switch_id}/replace}
   *
   * @param killSwitchId the {@code kill_switch_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode replaceKillSwitch(String killSwitchId, JsonNode body) {
    return replaceKillSwitch(killSwitchId, body, RequestOptions.none());
  }

  /**
   * Get the virtual clock.
   *
   * <p>{@code GET /v1/virtual_clock}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode getVirtualClock(RequestOptions options) {
    return requester.json(GET_VIRTUAL_CLOCK, List.of(), null, null, options);
  }

  /**
   * Get the virtual clock.
   *
   * <p>{@code GET /v1/virtual_clock}
   *
   * @return the response body
   */
  public JsonNode getVirtualClock() {
    return getVirtualClock(RequestOptions.none());
  }

  /**
   * Advance the virtual clock.
   *
   * <p>{@code POST /v1/virtual_clock/advance}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode advanceVirtualClock(JsonNode body, RequestOptions options) {
    return requester.json(ADVANCE_VIRTUAL_CLOCK, List.of(), null, body, options);
  }

  /**
   * Advance the virtual clock.
   *
   * <p>{@code POST /v1/virtual_clock/advance}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode advanceVirtualClock(JsonNode body) {
    return advanceVirtualClock(body, RequestOptions.none());
  }

  /**
   * List the simulated results of the fake provider.
   *
   * <p>{@code GET /v1/test/simulated-results}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode listSimulatedResults(RequestOptions options) {
    return requester.json(LIST_SIMULATED_RESULTS, List.of(), null, null, options);
  }

  /**
   * List the simulated results of the fake provider.
   *
   * <p>{@code GET /v1/test/simulated-results}
   *
   * @return the response body
   */
  public JsonNode listSimulatedResults() {
    return listSimulatedResults(RequestOptions.none());
  }

  /**
   * List the seed recipients of the test plane.
   *
   * <p>{@code GET /v1/test/seed-recipients}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode listSeedRecipients(RequestOptions options) {
    return requester.json(LIST_SEED_RECIPIENTS, List.of(), null, null, options);
  }

  /**
   * List the seed recipients of the test plane.
   *
   * <p>{@code GET /v1/test/seed-recipients}
   *
   * @return the response body
   */
  public JsonNode listSeedRecipients() {
    return listSeedRecipients(RequestOptions.none());
  }

  /**
   * Reset the seed recipients of the test plane.
   *
   * <p>{@code POST /v1/test/seed-recipients/reset}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode resetSeedRecipients(RequestOptions options) {
    return requester.json(RESET_SEED_RECIPIENTS, List.of(), null, null, options);
  }

  /**
   * Reset the seed recipients of the test plane.
   *
   * <p>{@code POST /v1/test/seed-recipients/reset}
   *
   * @return the response body
   */
  public JsonNode resetSeedRecipients() {
    return resetSeedRecipients(RequestOptions.none());
  }

  /**
   * List the test inbox.
   *
   * <p>{@code GET /v1/test/inbox}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listTestInboxMessages(ListTestInboxMessagesParams params, RequestOptions options) {
    return requester.page(LIST_TEST_INBOX_MESSAGES, List.of(), params, options);
  }

  /**
   * List the test inbox.
   *
   * <p>{@code GET /v1/test/inbox}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listTestInboxMessages() {
    return listTestInboxMessages(null, RequestOptions.none());
  }

  /**
   * List waitpoints.
   *
   * <p>{@code GET /v1/waitpoints}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listWaitpoints(ListWaitpointsParams params, RequestOptions options) {
    return requester.page(LIST_WAITPOINTS, List.of(), params, options);
  }

  /**
   * List waitpoints.
   *
   * <p>{@code GET /v1/waitpoints}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listWaitpoints() {
    return listWaitpoints(null, RequestOptions.none());
  }

  /**
   * Create a waitpoint.
   *
   * <p>{@code POST /v1/waitpoints}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createWaitpoint(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_WAITPOINT, List.of(), null, body, options);
  }

  /**
   * Create a waitpoint.
   *
   * <p>{@code POST /v1/waitpoints}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createWaitpoint(JsonNode body) {
    return createWaitpoint(body, RequestOptions.none());
  }

  /**
   * Get a waitpoint.
   *
   * <p>{@code GET /v1/waitpoints/{waitpoint_id}}
   *
   * @param waitpointId the {@code waitpoint_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getWaitpoint(String waitpointId, RequestOptions options) {
    return requester.json(GET_WAITPOINT, List.of(waitpointId), null, null, options);
  }

  /**
   * Get a waitpoint.
   *
   * <p>{@code GET /v1/waitpoints/{waitpoint_id}}
   *
   * @param waitpointId the {@code waitpoint_id} path parameter
   * @return the response body
   */
  public JsonNode getWaitpoint(String waitpointId) {
    return getWaitpoint(waitpointId, RequestOptions.none());
  }

  /**
   * Cancel a waitpoint.
   *
   * <p>{@code POST /v1/waitpoints/{waitpoint_id}/cancel}
   *
   * @param waitpointId the {@code waitpoint_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode cancelWaitpoint(String waitpointId, JsonNode body, RequestOptions options) {
    return requester.json(CANCEL_WAITPOINT, List.of(waitpointId), null, body, options);
  }

  /**
   * Cancel a waitpoint.
   *
   * <p>{@code POST /v1/waitpoints/{waitpoint_id}/cancel}
   *
   * @param waitpointId the {@code waitpoint_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode cancelWaitpoint(String waitpointId, JsonNode body) {
    return cancelWaitpoint(waitpointId, body, RequestOptions.none());
  }

  /**
   * Send a waiter heartbeat.
   *
   * <p>{@code POST /v1/waitpoints/{waitpoint_id}/heartbeat}
   *
   * @param waitpointId the {@code waitpoint_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode heartbeatWaitpoint(String waitpointId, RequestOptions options) {
    return requester.json(HEARTBEAT_WAITPOINT, List.of(waitpointId), null, null, options);
  }

  /**
   * Send a waiter heartbeat.
   *
   * <p>{@code POST /v1/waitpoints/{waitpoint_id}/heartbeat}
   *
   * @param waitpointId the {@code waitpoint_id} path parameter
   * @return the response body
   */
  public JsonNode heartbeatWaitpoint(String waitpointId) {
    return heartbeatWaitpoint(waitpointId, RequestOptions.none());
  }

  /**
   * Get the caller's mailbox.
   *
   * <p>{@code GET /v1/mailbox}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode getMailbox(RequestOptions options) {
    return requester.json(GET_MAILBOX, List.of(), null, null, options);
  }

  /**
   * Get the caller's mailbox.
   *
   * <p>{@code GET /v1/mailbox}
   *
   * @return the response body
   */
  public JsonNode getMailbox() {
    return getMailbox(RequestOptions.none());
  }

  /**
   * Lease mailbox records.
   *
   * <p>{@code POST /v1/mailbox/leases}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode leaseMailboxRecords(JsonNode body, RequestOptions options) {
    return requester.json(LEASE_MAILBOX_RECORDS, List.of(), null, body, options);
  }

  /**
   * Lease mailbox records.
   *
   * <p>{@code POST /v1/mailbox/leases}
   *
   * @return the response body
   */
  public JsonNode leaseMailboxRecords() {
    return leaseMailboxRecords(null, RequestOptions.none());
  }

  /**
   * Acknowledge mailbox records.
   *
   * <p>{@code POST /v1/mailbox/acks}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode ackMailboxRecords(JsonNode body, RequestOptions options) {
    return requester.json(ACK_MAILBOX_RECORDS, List.of(), null, body, options);
  }

  /**
   * Acknowledge mailbox records.
   *
   * <p>{@code POST /v1/mailbox/acks}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode ackMailboxRecords(JsonNode body) {
    return ackMailboxRecords(body, RequestOptions.none());
  }

  /**
   * Publish an AG-UI event.
   *
   * <p>{@code POST /v1/agui/events}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode publishAgUiEvent(JsonNode body, RequestOptions options) {
    return requester.json(PUBLISH_AG_UI_EVENT, List.of(), null, body, options);
  }

  /**
   * Publish an AG-UI event.
   *
   * <p>{@code POST /v1/agui/events}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode publishAgUiEvent(JsonNode body) {
    return publishAgUiEvent(body, RequestOptions.none());
  }

  /**
   * Call the MCP server.
   *
   * <p>{@code POST /v1/mcp}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode callMcp(JsonNode body, RequestOptions options) {
    return requester.json(CALL_MCP, List.of(), null, body, options);
  }

  /**
   * Call the MCP server.
   *
   * <p>{@code POST /v1/mcp}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode callMcp(JsonNode body) {
    return callMcp(body, RequestOptions.none());
  }

  /**
   * Read mailbox records in order.
   *
   * <p>{@code GET /v1/mailbox/records}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode listMailboxRecords(ListMailboxRecordsParams params, RequestOptions options) {
    return requester.json(LIST_MAILBOX_RECORDS, List.of(), params, null, options);
  }

  /**
   * Read mailbox records in order.
   *
   * <p>{@code GET /v1/mailbox/records}
   *
   * @return the response body
   */
  public JsonNode listMailboxRecords() {
    return listMailboxRecords(null, RequestOptions.none());
  }

  /**
   * Get a mailbox record by its handle.
   *
   * <p>{@code GET /v1/mailbox/records/{record_id}}
   *
   * @param recordId the {@code record_id} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode getMailboxRecord(
      String recordId, GetMailboxRecordParams params, RequestOptions options) {
    return requester.json(GET_MAILBOX_RECORD, List.of(recordId), params, null, options);
  }

  /**
   * Get a mailbox record by its handle.
   *
   * <p>{@code GET /v1/mailbox/records/{record_id}}
   *
   * @param recordId the {@code record_id} path parameter
   * @return the response body
   */
  public JsonNode getMailboxRecord(String recordId) {
    return getMailboxRecord(recordId, null, RequestOptions.none());
  }

  /**
   * List dead-lettered mailbox records.
   *
   * <p>{@code GET /v1/mailbox/dead_letters}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listMailboxDeadLetters(ListMailboxDeadLettersParams params, RequestOptions options) {
    return requester.page(LIST_MAILBOX_DEAD_LETTERS, List.of(), params, options);
  }

  /**
   * List dead-lettered mailbox records.
   *
   * <p>{@code GET /v1/mailbox/dead_letters}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listMailboxDeadLetters() {
    return listMailboxDeadLetters(null, RequestOptions.none());
  }

  /**
   * Send a message to an agent's mailbox.
   *
   * <p>{@code POST /v1/mailbox/messages}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode sendMailboxMessage(JsonNode body, RequestOptions options) {
    return requester.json(SEND_MAILBOX_MESSAGE, List.of(), null, body, options);
  }

  /**
   * Send a message to an agent's mailbox.
   *
   * <p>{@code POST /v1/mailbox/messages}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode sendMailboxMessage(JsonNode body) {
    return sendMailboxMessage(body, RequestOptions.none());
  }

  /**
   * List the request box.
   *
   * <p>{@code GET /v1/mailbox/requests}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listMailboxRequests(ListMailboxRequestsParams params, RequestOptions options) {
    return requester.page(LIST_MAILBOX_REQUESTS, List.of(), params, options);
  }

  /**
   * List the request box.
   *
   * <p>{@code GET /v1/mailbox/requests}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listMailboxRequests() {
    return listMailboxRequests(null, RequestOptions.none());
  }

  /**
   * Read the encrypted envelope of a message.
   *
   * <p>{@code GET /v1/mailbox/envelopes}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode getMailboxEnvelope(GetMailboxEnvelopeParams params, RequestOptions options) {
    return requester.json(GET_MAILBOX_ENVELOPE, List.of(), params, null, options);
  }

  /**
   * Read the encrypted envelope of a message.
   *
   * <p>{@code GET /v1/mailbox/envelopes}
   *
   * @param params the query parameters
   * @return the response body
   */
  public JsonNode getMailboxEnvelope(GetMailboxEnvelopeParams params) {
    return getMailboxEnvelope(params, RequestOptions.none());
  }

  /**
   * Block or unblock a sender.
   *
   * <p>{@code POST /v1/mailbox/blocks}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode setMailboxSenderBlock(JsonNode body, RequestOptions options) {
    return requester.json(SET_MAILBOX_SENDER_BLOCK, List.of(), null, body, options);
  }

  /**
   * Block or unblock a sender.
   *
   * <p>{@code POST /v1/mailbox/blocks}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode setMailboxSenderBlock(JsonNode body) {
    return setMailboxSenderBlock(body, RequestOptions.none());
  }

  /**
   * Report a mailbox message as abuse.
   *
   * <p>{@code POST /v1/mailbox/abuse_reports}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode reportMailboxAbuse(JsonNode body, RequestOptions options) {
    return requester.json(REPORT_MAILBOX_ABUSE, List.of(), null, body, options);
  }

  /**
   * Report a mailbox message as abuse.
   *
   * <p>{@code POST /v1/mailbox/abuse_reports}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode reportMailboxAbuse(JsonNode body) {
    return reportMailboxAbuse(body, RequestOptions.none());
  }

  /**
   * List escalation policies.
   *
   * <p>{@code GET /v1/escalation_policies}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listEscalationPolicies(ListEscalationPoliciesParams params, RequestOptions options) {
    return requester.page(LIST_ESCALATION_POLICIES, List.of(), params, options);
  }

  /**
   * List escalation policies.
   *
   * <p>{@code GET /v1/escalation_policies}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listEscalationPolicies() {
    return listEscalationPolicies(null, RequestOptions.none());
  }

  /**
   * Get an escalation policy.
   *
   * <p>{@code GET /v1/escalation_policies/{policy_key}}
   *
   * @param policyKey the {@code policy_key} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getEscalationPolicy(String policyKey, RequestOptions options) {
    return requester.json(GET_ESCALATION_POLICY, List.of(policyKey), null, null, options);
  }

  /**
   * Get an escalation policy.
   *
   * <p>{@code GET /v1/escalation_policies/{policy_key}}
   *
   * @param policyKey the {@code policy_key} path parameter
   * @return the response body
   */
  public JsonNode getEscalationPolicy(String policyKey) {
    return getEscalationPolicy(policyKey, RequestOptions.none());
  }

  /**
   * Write an escalation policy version.
   *
   * <p>{@code PUT /v1/escalation_policies/{policy_key}}
   *
   * @param policyKey the {@code policy_key} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode putEscalationPolicy(String policyKey, JsonNode body, RequestOptions options) {
    return requester.json(PUT_ESCALATION_POLICY, List.of(policyKey), null, body, options);
  }

  /**
   * Write an escalation policy version.
   *
   * <p>{@code PUT /v1/escalation_policies/{policy_key}}
   *
   * @param policyKey the {@code policy_key} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode putEscalationPolicy(String policyKey, JsonNode body) {
    return putEscalationPolicy(policyKey, body, RequestOptions.none());
  }

  /**
   * List escalation policy versions.
   *
   * <p>{@code GET /v1/escalation_policies/{policy_key}/versions}
   *
   * @param policyKey the {@code policy_key} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listEscalationPolicyVersions(
      String policyKey, ListEscalationPolicyVersionsParams params, RequestOptions options) {
    return requester.page(LIST_ESCALATION_POLICY_VERSIONS, List.of(policyKey), params, options);
  }

  /**
   * List escalation policy versions.
   *
   * <p>{@code GET /v1/escalation_policies/{policy_key}/versions}
   *
   * @param policyKey the {@code policy_key} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listEscalationPolicyVersions(String policyKey) {
    return listEscalationPolicyVersions(policyKey, null, RequestOptions.none());
  }

  /**
   * Archive an escalation policy.
   *
   * <p>{@code POST /v1/escalation_policies/{policy_key}/archive}
   *
   * @param policyKey the {@code policy_key} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode archiveEscalationPolicy(String policyKey, RequestOptions options) {
    return requester.json(ARCHIVE_ESCALATION_POLICY, List.of(policyKey), null, null, options);
  }

  /**
   * Archive an escalation policy.
   *
   * <p>{@code POST /v1/escalation_policies/{policy_key}/archive}
   *
   * @param policyKey the {@code policy_key} path parameter
   * @return the response body
   */
  public JsonNode archiveEscalationPolicy(String policyKey) {
    return archiveEscalationPolicy(policyKey, RequestOptions.none());
  }

  /**
   * List agents.
   *
   * <p>{@code GET /v1/agents}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listAgents(ListAgentsParams params, RequestOptions options) {
    return requester.page(LIST_AGENTS, List.of(), params, options);
  }

  /**
   * List agents.
   *
   * <p>{@code GET /v1/agents}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listAgents() {
    return listAgents(null, RequestOptions.none());
  }

  /**
   * Create an agent.
   *
   * <p>{@code POST /v1/agents}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createAgent(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_AGENT, List.of(), null, body, options);
  }

  /**
   * Create an agent.
   *
   * <p>{@code POST /v1/agents}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createAgent(JsonNode body) {
    return createAgent(body, RequestOptions.none());
  }

  /**
   * Get an agent.
   *
   * <p>{@code GET /v1/agents/{agent_id}}
   *
   * @param agentId the {@code agent_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getAgent(String agentId, RequestOptions options) {
    return requester.json(GET_AGENT, List.of(agentId), null, null, options);
  }

  /**
   * Get an agent.
   *
   * <p>{@code GET /v1/agents/{agent_id}}
   *
   * @param agentId the {@code agent_id} path parameter
   * @return the response body
   */
  public JsonNode getAgent(String agentId) {
    return getAgent(agentId, RequestOptions.none());
  }

  /**
   * Update an agent.
   *
   * <p>{@code PATCH /v1/agents/{agent_id}}
   *
   * @param agentId the {@code agent_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode updateAgent(String agentId, JsonNode body, RequestOptions options) {
    return requester.json(UPDATE_AGENT, List.of(agentId), null, body, options);
  }

  /**
   * Update an agent.
   *
   * <p>{@code PATCH /v1/agents/{agent_id}}
   *
   * @param agentId the {@code agent_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode updateAgent(String agentId, JsonNode body) {
    return updateAgent(agentId, body, RequestOptions.none());
  }

  /**
   * Delete an agent.
   *
   * <p>{@code DELETE /v1/agents/{agent_id}}
   *
   * @param agentId the {@code agent_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode deleteAgent(String agentId, RequestOptions options) {
    return requester.json(DELETE_AGENT, List.of(agentId), null, null, options);
  }

  /**
   * Delete an agent.
   *
   * <p>{@code DELETE /v1/agents/{agent_id}}
   *
   * @param agentId the {@code agent_id} path parameter
   * @return the response body
   */
  public JsonNode deleteAgent(String agentId) {
    return deleteAgent(agentId, RequestOptions.none());
  }

  /**
   * Decide on held agent notifications.
   *
   * <p>{@code POST /v1/agents/{agent_id}/ceiling_decisions}
   *
   * @param agentId the {@code agent_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createAgentCeilingDecision(
      String agentId, JsonNode body, RequestOptions options) {
    return requester.json(CREATE_AGENT_CEILING_DECISION, List.of(agentId), null, body, options);
  }

  /**
   * Decide on held agent notifications.
   *
   * <p>{@code POST /v1/agents/{agent_id}/ceiling_decisions}
   *
   * @param agentId the {@code agent_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode createAgentCeilingDecision(String agentId, JsonNode body) {
    return createAgentCeilingDecision(agentId, body, RequestOptions.none());
  }

  /**
   * List held agent notifications.
   *
   * <p>{@code GET /v1/agents/{agent_id}/ceiling_holds}
   *
   * @param agentId the {@code agent_id} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listAgentCeilingHolds(
      String agentId, ListAgentCeilingHoldsParams params, RequestOptions options) {
    return requester.page(LIST_AGENT_CEILING_HOLDS, List.of(agentId), params, options);
  }

  /**
   * List held agent notifications.
   *
   * <p>{@code GET /v1/agents/{agent_id}/ceiling_holds}
   *
   * @param agentId the {@code agent_id} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listAgentCeilingHolds(String agentId) {
    return listAgentCeilingHolds(agentId, null, RequestOptions.none());
  }

  /**
   * Resume a stopped agent.
   *
   * <p>{@code POST /v1/agents/{agent_id}/resume}
   *
   * @param agentId the {@code agent_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode resumeAgent(String agentId, JsonNode body, RequestOptions options) {
    return requester.json(RESUME_AGENT, List.of(agentId), null, body, options);
  }

  /**
   * Resume a stopped agent.
   *
   * <p>{@code POST /v1/agents/{agent_id}/resume}
   *
   * @param agentId the {@code agent_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode resumeAgent(String agentId, JsonNode body) {
    return resumeAgent(agentId, body, RequestOptions.none());
  }

  /**
   * List webhook consumers.
   *
   * <p>{@code GET /v1/webhook_consumers}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookConsumers(ListWebhookConsumersParams params, RequestOptions options) {
    return requester.page(LIST_WEBHOOK_CONSUMERS, List.of(), params, options);
  }

  /**
   * List webhook consumers.
   *
   * <p>{@code GET /v1/webhook_consumers}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookConsumers() {
    return listWebhookConsumers(null, RequestOptions.none());
  }

  /**
   * Create a webhook consumer.
   *
   * <p>{@code POST /v1/webhook_consumers}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createWebhookConsumer(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_WEBHOOK_CONSUMER, List.of(), null, body, options);
  }

  /**
   * Create a webhook consumer.
   *
   * <p>{@code POST /v1/webhook_consumers}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createWebhookConsumer(JsonNode body) {
    return createWebhookConsumer(body, RequestOptions.none());
  }

  /**
   * Get a webhook consumer.
   *
   * <p>{@code GET /v1/webhook_consumers/{webhook_consumer_id}}
   *
   * @param webhookConsumerId the {@code webhook_consumer_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getWebhookConsumer(String webhookConsumerId, RequestOptions options) {
    return requester.json(GET_WEBHOOK_CONSUMER, List.of(webhookConsumerId), null, null, options);
  }

  /**
   * Get a webhook consumer.
   *
   * <p>{@code GET /v1/webhook_consumers/{webhook_consumer_id}}
   *
   * @param webhookConsumerId the {@code webhook_consumer_id} path parameter
   * @return the response body
   */
  public JsonNode getWebhookConsumer(String webhookConsumerId) {
    return getWebhookConsumer(webhookConsumerId, RequestOptions.none());
  }

  /**
   * Update a webhook consumer.
   *
   * <p>{@code PATCH /v1/webhook_consumers/{webhook_consumer_id}}
   *
   * @param webhookConsumerId the {@code webhook_consumer_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode updateWebhookConsumer(
      String webhookConsumerId, JsonNode body, RequestOptions options) {
    return requester.json(UPDATE_WEBHOOK_CONSUMER, List.of(webhookConsumerId), null, body, options);
  }

  /**
   * Update a webhook consumer.
   *
   * <p>{@code PATCH /v1/webhook_consumers/{webhook_consumer_id}}
   *
   * @param webhookConsumerId the {@code webhook_consumer_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode updateWebhookConsumer(String webhookConsumerId, JsonNode body) {
    return updateWebhookConsumer(webhookConsumerId, body, RequestOptions.none());
  }

  /**
   * Archive a webhook consumer.
   *
   * <p>{@code POST /v1/webhook_consumers/{webhook_consumer_id}/archive}
   *
   * @param webhookConsumerId the {@code webhook_consumer_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode archiveWebhookConsumer(String webhookConsumerId, RequestOptions options) {
    return requester.json(
        ARCHIVE_WEBHOOK_CONSUMER, List.of(webhookConsumerId), null, null, options);
  }

  /**
   * Archive a webhook consumer.
   *
   * <p>{@code POST /v1/webhook_consumers/{webhook_consumer_id}/archive}
   *
   * @param webhookConsumerId the {@code webhook_consumer_id} path parameter
   * @return the response body
   */
  public JsonNode archiveWebhookConsumer(String webhookConsumerId) {
    return archiveWebhookConsumer(webhookConsumerId, RequestOptions.none());
  }

  /**
   * List completion sources.
   *
   * <p>{@code GET /v1/webhook_sources}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookSources(ListWebhookSourcesParams params, RequestOptions options) {
    return requester.page(LIST_WEBHOOK_SOURCES, List.of(), params, options);
  }

  /**
   * List completion sources.
   *
   * <p>{@code GET /v1/webhook_sources}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookSources() {
    return listWebhookSources(null, RequestOptions.none());
  }

  /**
   * Register a completion source.
   *
   * <p>{@code POST /v1/webhook_sources}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createWebhookSource(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_WEBHOOK_SOURCE, List.of(), null, body, options);
  }

  /**
   * Register a completion source.
   *
   * <p>{@code POST /v1/webhook_sources}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createWebhookSource(JsonNode body) {
    return createWebhookSource(body, RequestOptions.none());
  }

  /**
   * Get a completion source.
   *
   * <p>{@code GET /v1/webhook_sources/{webhook_source_id}}
   *
   * @param webhookSourceId the {@code webhook_source_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getWebhookSource(String webhookSourceId, RequestOptions options) {
    return requester.json(GET_WEBHOOK_SOURCE, List.of(webhookSourceId), null, null, options);
  }

  /**
   * Get a completion source.
   *
   * <p>{@code GET /v1/webhook_sources/{webhook_source_id}}
   *
   * @param webhookSourceId the {@code webhook_source_id} path parameter
   * @return the response body
   */
  public JsonNode getWebhookSource(String webhookSourceId) {
    return getWebhookSource(webhookSourceId, RequestOptions.none());
  }

  /**
   * Archive a completion source.
   *
   * <p>{@code POST /v1/webhook_sources/{webhook_source_id}/archive}
   *
   * @param webhookSourceId the {@code webhook_source_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode archiveWebhookSource(String webhookSourceId, RequestOptions options) {
    return requester.json(ARCHIVE_WEBHOOK_SOURCE, List.of(webhookSourceId), null, null, options);
  }

  /**
   * Archive a completion source.
   *
   * <p>{@code POST /v1/webhook_sources/{webhook_source_id}/archive}
   *
   * @param webhookSourceId the {@code webhook_source_id} path parameter
   * @return the response body
   */
  public JsonNode archiveWebhookSource(String webhookSourceId) {
    return archiveWebhookSource(webhookSourceId, RequestOptions.none());
  }

  /**
   * Mint a webhook portal token.
   *
   * <p>{@code POST /v1/webhook_consumers/{webhook_consumer_id}/portal_tokens}
   *
   * @param webhookConsumerId the {@code webhook_consumer_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode createWebhookPortalToken(String webhookConsumerId, RequestOptions options) {
    return requester.json(
        CREATE_WEBHOOK_PORTAL_TOKEN, List.of(webhookConsumerId), null, null, options);
  }

  /**
   * Mint a webhook portal token.
   *
   * <p>{@code POST /v1/webhook_consumers/{webhook_consumer_id}/portal_tokens}
   *
   * @param webhookConsumerId the {@code webhook_consumer_id} path parameter
   * @return the response body
   */
  public JsonNode createWebhookPortalToken(String webhookConsumerId) {
    return createWebhookPortalToken(webhookConsumerId, RequestOptions.none());
  }

  /**
   * List tenant event types.
   *
   * <p>{@code GET /v1/webhook_event_types}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookEventTypes(ListWebhookEventTypesParams params, RequestOptions options) {
    return requester.page(LIST_WEBHOOK_EVENT_TYPES, List.of(), params, options);
  }

  /**
   * List tenant event types.
   *
   * <p>{@code GET /v1/webhook_event_types}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookEventTypes() {
    return listWebhookEventTypes(null, RequestOptions.none());
  }

  /**
   * Create a tenant event type.
   *
   * <p>{@code POST /v1/webhook_event_types}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createWebhookEventType(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_WEBHOOK_EVENT_TYPE, List.of(), null, body, options);
  }

  /**
   * Create a tenant event type.
   *
   * <p>{@code POST /v1/webhook_event_types}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createWebhookEventType(JsonNode body) {
    return createWebhookEventType(body, RequestOptions.none());
  }

  /**
   * Get a tenant event type.
   *
   * <p>{@code GET /v1/webhook_event_types/{webhook_event_type_id}}
   *
   * @param webhookEventTypeId the {@code webhook_event_type_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getWebhookEventType(String webhookEventTypeId, RequestOptions options) {
    return requester.json(GET_WEBHOOK_EVENT_TYPE, List.of(webhookEventTypeId), null, null, options);
  }

  /**
   * Get a tenant event type.
   *
   * <p>{@code GET /v1/webhook_event_types/{webhook_event_type_id}}
   *
   * @param webhookEventTypeId the {@code webhook_event_type_id} path parameter
   * @return the response body
   */
  public JsonNode getWebhookEventType(String webhookEventTypeId) {
    return getWebhookEventType(webhookEventTypeId, RequestOptions.none());
  }

  /**
   * Archive a tenant event type.
   *
   * <p>{@code POST /v1/webhook_event_types/{webhook_event_type_id}/archive}
   *
   * @param webhookEventTypeId the {@code webhook_event_type_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode archiveWebhookEventType(String webhookEventTypeId, RequestOptions options) {
    return requester.json(
        ARCHIVE_WEBHOOK_EVENT_TYPE, List.of(webhookEventTypeId), null, null, options);
  }

  /**
   * Archive a tenant event type.
   *
   * <p>{@code POST /v1/webhook_event_types/{webhook_event_type_id}/archive}
   *
   * @param webhookEventTypeId the {@code webhook_event_type_id} path parameter
   * @return the response body
   */
  public JsonNode archiveWebhookEventType(String webhookEventTypeId) {
    return archiveWebhookEventType(webhookEventTypeId, RequestOptions.none());
  }

  /**
   * List the schema versions of a tenant event type.
   *
   * <p>{@code GET /v1/webhook_event_types/{webhook_event_type_id}/versions}
   *
   * @param webhookEventTypeId the {@code webhook_event_type_id} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookEventTypeVersions(
      String webhookEventTypeId,
      ListWebhookEventTypeVersionsParams params,
      RequestOptions options) {
    return requester.page(
        LIST_WEBHOOK_EVENT_TYPE_VERSIONS, List.of(webhookEventTypeId), params, options);
  }

  /**
   * List the schema versions of a tenant event type.
   *
   * <p>{@code GET /v1/webhook_event_types/{webhook_event_type_id}/versions}
   *
   * @param webhookEventTypeId the {@code webhook_event_type_id} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookEventTypeVersions(String webhookEventTypeId) {
    return listWebhookEventTypeVersions(webhookEventTypeId, null, RequestOptions.none());
  }

  /**
   * Add a schema version to a tenant event type.
   *
   * <p>{@code POST /v1/webhook_event_types/{webhook_event_type_id}/versions}
   *
   * @param webhookEventTypeId the {@code webhook_event_type_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createWebhookEventTypeVersion(
      String webhookEventTypeId, JsonNode body, RequestOptions options) {
    return requester.json(
        CREATE_WEBHOOK_EVENT_TYPE_VERSION, List.of(webhookEventTypeId), null, body, options);
  }

  /**
   * Add a schema version to a tenant event type.
   *
   * <p>{@code POST /v1/webhook_event_types/{webhook_event_type_id}/versions}
   *
   * @param webhookEventTypeId the {@code webhook_event_type_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode createWebhookEventTypeVersion(String webhookEventTypeId, JsonNode body) {
    return createWebhookEventTypeVersion(webhookEventTypeId, body, RequestOptions.none());
  }

  /**
   * Get a schema version of a tenant event type.
   *
   * <p>{@code GET /v1/webhook_event_types/{webhook_event_type_id}/versions/{version}}
   *
   * @param webhookEventTypeId the {@code webhook_event_type_id} path parameter
   * @param version the {@code version} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getWebhookEventTypeVersion(
      String webhookEventTypeId, String version, RequestOptions options) {
    return requester.json(
        GET_WEBHOOK_EVENT_TYPE_VERSION, List.of(webhookEventTypeId, version), null, null, options);
  }

  /**
   * Get a schema version of a tenant event type.
   *
   * <p>{@code GET /v1/webhook_event_types/{webhook_event_type_id}/versions/{version}}
   *
   * @param webhookEventTypeId the {@code webhook_event_type_id} path parameter
   * @param version the {@code version} path parameter
   * @return the response body
   */
  public JsonNode getWebhookEventTypeVersion(String webhookEventTypeId, String version) {
    return getWebhookEventTypeVersion(webhookEventTypeId, version, RequestOptions.none());
  }

  /**
   * List Relay's event catalog.
   *
   * <p>{@code GET /v1/webhook_catalog}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookCatalog(ListWebhookCatalogParams params, RequestOptions options) {
    return requester.page(LIST_WEBHOOK_CATALOG, List.of(), params, options);
  }

  /**
   * List Relay's event catalog.
   *
   * <p>{@code GET /v1/webhook_catalog}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookCatalog() {
    return listWebhookCatalog(null, RequestOptions.none());
  }

  /**
   * List webhook endpoints.
   *
   * <p>{@code GET /v1/webhook_endpoints}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookEndpoints(ListWebhookEndpointsParams params, RequestOptions options) {
    return requester.page(LIST_WEBHOOK_ENDPOINTS, List.of(), params, options);
  }

  /**
   * List webhook endpoints.
   *
   * <p>{@code GET /v1/webhook_endpoints}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookEndpoints() {
    return listWebhookEndpoints(null, RequestOptions.none());
  }

  /**
   * Create a webhook endpoint.
   *
   * <p>{@code POST /v1/webhook_endpoints}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createWebhookEndpoint(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_WEBHOOK_ENDPOINT, List.of(), null, body, options);
  }

  /**
   * Create a webhook endpoint.
   *
   * <p>{@code POST /v1/webhook_endpoints}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createWebhookEndpoint(JsonNode body) {
    return createWebhookEndpoint(body, RequestOptions.none());
  }

  /**
   * Get a webhook endpoint.
   *
   * <p>{@code GET /v1/webhook_endpoints/{webhook_endpoint_id}}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getWebhookEndpoint(String webhookEndpointId, RequestOptions options) {
    return requester.json(GET_WEBHOOK_ENDPOINT, List.of(webhookEndpointId), null, null, options);
  }

  /**
   * Get a webhook endpoint.
   *
   * <p>{@code GET /v1/webhook_endpoints/{webhook_endpoint_id}}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @return the response body
   */
  public JsonNode getWebhookEndpoint(String webhookEndpointId) {
    return getWebhookEndpoint(webhookEndpointId, RequestOptions.none());
  }

  /**
   * Update a webhook endpoint.
   *
   * <p>{@code PATCH /v1/webhook_endpoints/{webhook_endpoint_id}}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode updateWebhookEndpoint(
      String webhookEndpointId, JsonNode body, RequestOptions options) {
    return requester.json(UPDATE_WEBHOOK_ENDPOINT, List.of(webhookEndpointId), null, body, options);
  }

  /**
   * Update a webhook endpoint.
   *
   * <p>{@code PATCH /v1/webhook_endpoints/{webhook_endpoint_id}}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode updateWebhookEndpoint(String webhookEndpointId, JsonNode body) {
    return updateWebhookEndpoint(webhookEndpointId, body, RequestOptions.none());
  }

  /**
   * Archive a webhook endpoint.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/archive}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode archiveWebhookEndpoint(String webhookEndpointId, RequestOptions options) {
    return requester.json(
        ARCHIVE_WEBHOOK_ENDPOINT, List.of(webhookEndpointId), null, null, options);
  }

  /**
   * Archive a webhook endpoint.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/archive}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @return the response body
   */
  public JsonNode archiveWebhookEndpoint(String webhookEndpointId) {
    return archiveWebhookEndpoint(webhookEndpointId, RequestOptions.none());
  }

  /**
   * Rotate a webhook endpoint's signing key.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/rotate_key}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode rotateWebhookEndpointKey(
      String webhookEndpointId, JsonNode body, RequestOptions options) {
    return requester.json(
        ROTATE_WEBHOOK_ENDPOINT_KEY, List.of(webhookEndpointId), null, body, options);
  }

  /**
   * Rotate a webhook endpoint's signing key.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/rotate_key}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @return the response body
   */
  public JsonNode rotateWebhookEndpointKey(String webhookEndpointId) {
    return rotateWebhookEndpointKey(webhookEndpointId, null, RequestOptions.none());
  }

  /**
   * List the versions of an endpoint.
   *
   * <p>{@code GET /v1/webhook_endpoints/{webhook_endpoint_id}/versions}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookEndpointVersions(
      String webhookEndpointId, ListWebhookEndpointVersionsParams params, RequestOptions options) {
    return requester.page(
        LIST_WEBHOOK_ENDPOINT_VERSIONS, List.of(webhookEndpointId), params, options);
  }

  /**
   * List the versions of an endpoint.
   *
   * <p>{@code GET /v1/webhook_endpoints/{webhook_endpoint_id}/versions}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookEndpointVersions(String webhookEndpointId) {
    return listWebhookEndpointVersions(webhookEndpointId, null, RequestOptions.none());
  }

  /**
   * Get a version of an endpoint.
   *
   * <p>{@code GET /v1/webhook_endpoints/{webhook_endpoint_id}/versions/{version}}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param version the {@code version} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getWebhookEndpointVersion(
      String webhookEndpointId, String version, RequestOptions options) {
    return requester.json(
        GET_WEBHOOK_ENDPOINT_VERSION, List.of(webhookEndpointId, version), null, null, options);
  }

  /**
   * Get a version of an endpoint.
   *
   * <p>{@code GET /v1/webhook_endpoints/{webhook_endpoint_id}/versions/{version}}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param version the {@code version} path parameter
   * @return the response body
   */
  public JsonNode getWebhookEndpointVersion(String webhookEndpointId, String version) {
    return getWebhookEndpointVersion(webhookEndpointId, version, RequestOptions.none());
  }

  /**
   * Pause a webhook endpoint.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/pause}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode pauseWebhookEndpoint(String webhookEndpointId, RequestOptions options) {
    return requester.json(PAUSE_WEBHOOK_ENDPOINT, List.of(webhookEndpointId), null, null, options);
  }

  /**
   * Pause a webhook endpoint.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/pause}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @return the response body
   */
  public JsonNode pauseWebhookEndpoint(String webhookEndpointId) {
    return pauseWebhookEndpoint(webhookEndpointId, RequestOptions.none());
  }

  /**
   * Resume a webhook endpoint.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/resume}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode resumeWebhookEndpoint(String webhookEndpointId, RequestOptions options) {
    return requester.json(RESUME_WEBHOOK_ENDPOINT, List.of(webhookEndpointId), null, null, options);
  }

  /**
   * Resume a webhook endpoint.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/resume}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @return the response body
   */
  public JsonNode resumeWebhookEndpoint(String webhookEndpointId) {
    return resumeWebhookEndpoint(webhookEndpointId, RequestOptions.none());
  }

  /**
   * Get the health of an endpoint.
   *
   * <p>{@code GET /v1/webhook_endpoints/{webhook_endpoint_id}/health}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getWebhookEndpointHealth(String webhookEndpointId, RequestOptions options) {
    return requester.json(
        GET_WEBHOOK_ENDPOINT_HEALTH, List.of(webhookEndpointId), null, null, options);
  }

  /**
   * Get the health of an endpoint.
   *
   * <p>{@code GET /v1/webhook_endpoints/{webhook_endpoint_id}/health}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @return the response body
   */
  public JsonNode getWebhookEndpointHealth(String webhookEndpointId) {
    return getWebhookEndpointHealth(webhookEndpointId, RequestOptions.none());
  }

  /**
   * Send a test event.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/test}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode sendWebhookEndpointTestEvent(
      String webhookEndpointId, JsonNode body, RequestOptions options) {
    return requester.json(
        SEND_WEBHOOK_ENDPOINT_TEST_EVENT, List.of(webhookEndpointId), null, body, options);
  }

  /**
   * Send a test event.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/test}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @return the response body
   */
  public JsonNode sendWebhookEndpointTestEvent(String webhookEndpointId) {
    return sendWebhookEndpointTestEvent(webhookEndpointId, null, RequestOptions.none());
  }

  /**
   * Recover an endpoint.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/recover}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode recoverWebhookEndpoint(
      String webhookEndpointId, JsonNode body, RequestOptions options) {
    return requester.json(
        RECOVER_WEBHOOK_ENDPOINT, List.of(webhookEndpointId), null, body, options);
  }

  /**
   * Recover an endpoint.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/recover}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode recoverWebhookEndpoint(String webhookEndpointId, JsonNode body) {
    return recoverWebhookEndpoint(webhookEndpointId, body, RequestOptions.none());
  }

  /**
   * Retry messages in bulk.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/retry}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode retryWebhookEndpointMessages(
      String webhookEndpointId, JsonNode body, RequestOptions options) {
    return requester.json(
        RETRY_WEBHOOK_ENDPOINT_MESSAGES, List.of(webhookEndpointId), null, body, options);
  }

  /**
   * Retry messages in bulk.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/retry}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode retryWebhookEndpointMessages(String webhookEndpointId, JsonNode body) {
    return retryWebhookEndpointMessages(webhookEndpointId, body, RequestOptions.none());
  }

  /**
   * Replay events to an endpoint.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/replay}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replayWebhookEndpointEvents(
      String webhookEndpointId, JsonNode body, RequestOptions options) {
    return requester.json(
        REPLAY_WEBHOOK_ENDPOINT_EVENTS, List.of(webhookEndpointId), null, body, options);
  }

  /**
   * Replay events to an endpoint.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/replay}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode replayWebhookEndpointEvents(String webhookEndpointId, JsonNode body) {
    return replayWebhookEndpointEvents(webhookEndpointId, body, RequestOptions.none());
  }

  /**
   * Cancel scheduled retries.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/cancel_retries}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode cancelWebhookEndpointRetries(
      String webhookEndpointId, JsonNode body, RequestOptions options) {
    return requester.json(
        CANCEL_WEBHOOK_ENDPOINT_RETRIES, List.of(webhookEndpointId), null, body, options);
  }

  /**
   * Cancel scheduled retries.
   *
   * <p>{@code POST /v1/webhook_endpoints/{webhook_endpoint_id}/cancel_retries}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @return the response body
   */
  public JsonNode cancelWebhookEndpointRetries(String webhookEndpointId) {
    return cancelWebhookEndpointRetries(webhookEndpointId, null, RequestOptions.none());
  }

  /**
   * List missed events.
   *
   * <p>{@code GET /v1/webhook_endpoints/{webhook_endpoint_id}/missed_events}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookEndpointMissedEvents(
      String webhookEndpointId,
      ListWebhookEndpointMissedEventsParams params,
      RequestOptions options) {
    return requester.page(
        LIST_WEBHOOK_ENDPOINT_MISSED_EVENTS, List.of(webhookEndpointId), params, options);
  }

  /**
   * List missed events.
   *
   * <p>{@code GET /v1/webhook_endpoints/{webhook_endpoint_id}/missed_events}
   *
   * @param webhookEndpointId the {@code webhook_endpoint_id} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookEndpointMissedEvents(String webhookEndpointId) {
    return listWebhookEndpointMissedEvents(webhookEndpointId, null, RequestOptions.none());
  }

  /**
   * List webhook events.
   *
   * <p>{@code GET /v1/webhook_events}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookEvents(ListWebhookEventsParams params, RequestOptions options) {
    return requester.page(LIST_WEBHOOK_EVENTS, List.of(), params, options);
  }

  /**
   * List webhook events.
   *
   * <p>{@code GET /v1/webhook_events}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookEvents() {
    return listWebhookEvents(null, RequestOptions.none());
  }

  /**
   * List webhook messages.
   *
   * <p>{@code GET /v1/webhook_messages}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookMessages(ListWebhookMessagesParams params, RequestOptions options) {
    return requester.page(LIST_WEBHOOK_MESSAGES, List.of(), params, options);
  }

  /**
   * List webhook messages.
   *
   * <p>{@code GET /v1/webhook_messages}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookMessages() {
    return listWebhookMessages(null, RequestOptions.none());
  }

  /**
   * Get a webhook message.
   *
   * <p>{@code GET /v1/webhook_messages/{webhook_message_id}}
   *
   * @param webhookMessageId the {@code webhook_message_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getWebhookMessage(String webhookMessageId, RequestOptions options) {
    return requester.json(GET_WEBHOOK_MESSAGE, List.of(webhookMessageId), null, null, options);
  }

  /**
   * Get a webhook message.
   *
   * <p>{@code GET /v1/webhook_messages/{webhook_message_id}}
   *
   * @param webhookMessageId the {@code webhook_message_id} path parameter
   * @return the response body
   */
  public JsonNode getWebhookMessage(String webhookMessageId) {
    return getWebhookMessage(webhookMessageId, RequestOptions.none());
  }

  /**
   * List the attempts of a message.
   *
   * <p>{@code GET /v1/webhook_messages/{webhook_message_id}/attempts}
   *
   * @param webhookMessageId the {@code webhook_message_id} path parameter
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookMessageAttempts(
      String webhookMessageId, ListWebhookMessageAttemptsParams params, RequestOptions options) {
    return requester.page(
        LIST_WEBHOOK_MESSAGE_ATTEMPTS, List.of(webhookMessageId), params, options);
  }

  /**
   * List the attempts of a message.
   *
   * <p>{@code GET /v1/webhook_messages/{webhook_message_id}/attempts}
   *
   * @param webhookMessageId the {@code webhook_message_id} path parameter
   * @return the first page; further pages are fetched lazily
   */
  public Page listWebhookMessageAttempts(String webhookMessageId) {
    return listWebhookMessageAttempts(webhookMessageId, null, RequestOptions.none());
  }

  /**
   * Get an attempt of a message.
   *
   * <p>{@code GET /v1/webhook_messages/{webhook_message_id}/attempts/{webhook_attempt_id}}
   *
   * @param webhookMessageId the {@code webhook_message_id} path parameter
   * @param webhookAttemptId the {@code webhook_attempt_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getWebhookMessageAttempt(
      String webhookMessageId, String webhookAttemptId, RequestOptions options) {
    return requester.json(
        GET_WEBHOOK_MESSAGE_ATTEMPT,
        List.of(webhookMessageId, webhookAttemptId),
        null,
        null,
        options);
  }

  /**
   * Get an attempt of a message.
   *
   * <p>{@code GET /v1/webhook_messages/{webhook_message_id}/attempts/{webhook_attempt_id}}
   *
   * @param webhookMessageId the {@code webhook_message_id} path parameter
   * @param webhookAttemptId the {@code webhook_attempt_id} path parameter
   * @return the response body
   */
  public JsonNode getWebhookMessageAttempt(String webhookMessageId, String webhookAttemptId) {
    return getWebhookMessageAttempt(webhookMessageId, webhookAttemptId, RequestOptions.none());
  }

  /**
   * Resend a webhook message.
   *
   * <p>{@code POST /v1/webhook_messages/{webhook_message_id}/resend}
   *
   * @param webhookMessageId the {@code webhook_message_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode resendWebhookMessage(String webhookMessageId, RequestOptions options) {
    return requester.json(RESEND_WEBHOOK_MESSAGE, List.of(webhookMessageId), null, null, options);
  }

  /**
   * Resend a webhook message.
   *
   * <p>{@code POST /v1/webhook_messages/{webhook_message_id}/resend}
   *
   * @param webhookMessageId the {@code webhook_message_id} path parameter
   * @return the response body
   */
  public JsonNode resendWebhookMessage(String webhookMessageId) {
    return resendWebhookMessage(webhookMessageId, RequestOptions.none());
  }

  /**
   * Cancel a webhook message.
   *
   * <p>{@code POST /v1/webhook_messages/{webhook_message_id}/cancel}
   *
   * @param webhookMessageId the {@code webhook_message_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode cancelWebhookMessage(String webhookMessageId, RequestOptions options) {
    return requester.json(CANCEL_WEBHOOK_MESSAGE, List.of(webhookMessageId), null, null, options);
  }

  /**
   * Cancel a webhook message.
   *
   * <p>{@code POST /v1/webhook_messages/{webhook_message_id}/cancel}
   *
   * @param webhookMessageId the {@code webhook_message_id} path parameter
   * @return the response body
   */
  public JsonNode cancelWebhookMessage(String webhookMessageId) {
    return cancelWebhookMessage(webhookMessageId, RequestOptions.none());
  }

  /**
   * Get the operations contacts.
   *
   * <p>{@code GET /v1/operations_contacts}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode getOperationsContacts(RequestOptions options) {
    return requester.json(GET_OPERATIONS_CONTACTS, List.of(), null, null, options);
  }

  /**
   * Get the operations contacts.
   *
   * <p>{@code GET /v1/operations_contacts}
   *
   * @return the response body
   */
  public JsonNode getOperationsContacts() {
    return getOperationsContacts(RequestOptions.none());
  }

  /**
   * Replace the operations contacts.
   *
   * <p>{@code PUT /v1/operations_contacts}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replaceOperationsContacts(JsonNode body, RequestOptions options) {
    return requester.json(REPLACE_OPERATIONS_CONTACTS, List.of(), null, body, options);
  }

  /**
   * Replace the operations contacts.
   *
   * <p>{@code PUT /v1/operations_contacts}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode replaceOperationsContacts(JsonNode body) {
    return replaceOperationsContacts(body, RequestOptions.none());
  }

  /**
   * Get the İYS configuration.
   *
   * <p>{@code GET /v1/iys/config}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode getIysConfig(RequestOptions options) {
    return requester.json(GET_IYS_CONFIG, List.of(), null, null, options);
  }

  /**
   * Get the İYS configuration.
   *
   * <p>{@code GET /v1/iys/config}
   *
   * @return the response body
   */
  public JsonNode getIysConfig() {
    return getIysConfig(RequestOptions.none());
  }

  /**
   * Replace the İYS configuration.
   *
   * <p>{@code PUT /v1/iys/config}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replaceIysConfig(JsonNode body, RequestOptions options) {
    return requester.json(REPLACE_IYS_CONFIG, List.of(), null, body, options);
  }

  /**
   * Replace the İYS configuration.
   *
   * <p>{@code PUT /v1/iys/config}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode replaceIysConfig(JsonNode body) {
    return replaceIysConfig(body, RequestOptions.none());
  }

  /**
   * List the İYS brands.
   *
   * <p>{@code GET /v1/iys/brands}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode listIysBrands(RequestOptions options) {
    return requester.json(LIST_IYS_BRANDS, List.of(), null, null, options);
  }

  /**
   * List the İYS brands.
   *
   * <p>{@code GET /v1/iys/brands}
   *
   * @return the response body
   */
  public JsonNode listIysBrands() {
    return listIysBrands(RequestOptions.none());
  }

  /**
   * Test the İYS connection.
   *
   * <p>{@code GET /v1/iys/connection_test}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode testIysConnection(RequestOptions options) {
    return requester.json(TEST_IYS_CONNECTION, List.of(), null, null, options);
  }

  /**
   * Test the İYS connection.
   *
   * <p>{@code GET /v1/iys/connection_test}
   *
   * @return the response body
   */
  public JsonNode testIysConnection() {
    return testIysConnection(RequestOptions.none());
  }

  /**
   * List İYS uploads.
   *
   * <p>{@code GET /v1/iys/uploads}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listIysUploads(ListIysUploadsParams params, RequestOptions options) {
    return requester.page(LIST_IYS_UPLOADS, List.of(), params, options);
  }

  /**
   * List İYS uploads.
   *
   * <p>{@code GET /v1/iys/uploads}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listIysUploads() {
    return listIysUploads(null, RequestOptions.none());
  }

  /**
   * Put a subscriber's messaging conversation.
   *
   * <p>{@code PUT /v1/subscribers/{subscriber_id}/messaging_targets/{channel}}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param channel the {@code channel} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode replaceSubscriberMessagingTarget(
      String subscriberId, String channel, JsonNode body, RequestOptions options) {
    return requester.json(
        REPLACE_SUBSCRIBER_MESSAGING_TARGET, List.of(subscriberId, channel), null, body, options);
  }

  /**
   * Put a subscriber's messaging conversation.
   *
   * <p>{@code PUT /v1/subscribers/{subscriber_id}/messaging_targets/{channel}}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param channel the {@code channel} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode replaceSubscriberMessagingTarget(
      String subscriberId, String channel, JsonNode body) {
    return replaceSubscriberMessagingTarget(subscriberId, channel, body, RequestOptions.none());
  }

  /**
   * Remove a subscriber's messaging conversation.
   *
   * <p>{@code DELETE /v1/subscribers/{subscriber_id}/messaging_targets/{channel}}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param channel the {@code channel} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode deleteSubscriberMessagingTarget(
      String subscriberId, String channel, RequestOptions options) {
    return requester.json(
        DELETE_SUBSCRIBER_MESSAGING_TARGET, List.of(subscriberId, channel), null, null, options);
  }

  /**
   * Remove a subscriber's messaging conversation.
   *
   * <p>{@code DELETE /v1/subscribers/{subscriber_id}/messaging_targets/{channel}}
   *
   * @param subscriberId the {@code subscriber_id} path parameter
   * @param channel the {@code channel} path parameter
   * @return the response body
   */
  public JsonNode deleteSubscriberMessagingTarget(String subscriberId, String channel) {
    return deleteSubscriberMessagingTarget(subscriberId, channel, RequestOptions.none());
  }

  /**
   * Install a messaging channel identity in a workspace.
   *
   * <p>{@code POST /v1/messaging_installations}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createMessagingInstallation(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_MESSAGING_INSTALLATION, List.of(), null, body, options);
  }

  /**
   * Install a messaging channel identity in a workspace.
   *
   * <p>{@code POST /v1/messaging_installations}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createMessagingInstallation(JsonNode body) {
    return createMessagingInstallation(body, RequestOptions.none());
  }

  /**
   * List channel adapters.
   *
   * <p>{@code GET /v1/channel_adapters}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode listChannelAdapters(RequestOptions options) {
    return requester.json(LIST_CHANNEL_ADAPTERS, List.of(), null, null, options);
  }

  /**
   * List channel adapters.
   *
   * <p>{@code GET /v1/channel_adapters}
   *
   * @return the response body
   */
  public JsonNode listChannelAdapters() {
    return listChannelAdapters(RequestOptions.none());
  }

  /**
   * List WhatsApp templates.
   *
   * <p>{@code GET /v1/whatsapp/templates}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listWhatsappTemplates(ListWhatsappTemplatesParams params, RequestOptions options) {
    return requester.page(LIST_WHATSAPP_TEMPLATES, List.of(), params, options);
  }

  /**
   * List WhatsApp templates.
   *
   * <p>{@code GET /v1/whatsapp/templates}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listWhatsappTemplates() {
    return listWhatsappTemplates(null, RequestOptions.none());
  }

  /**
   * Register a WhatsApp template.
   *
   * <p>{@code POST /v1/whatsapp/templates}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode registerWhatsappTemplate(JsonNode body, RequestOptions options) {
    return requester.json(REGISTER_WHATSAPP_TEMPLATE, List.of(), null, body, options);
  }

  /**
   * Register a WhatsApp template.
   *
   * <p>{@code POST /v1/whatsapp/templates}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode registerWhatsappTemplate(JsonNode body) {
    return registerWhatsappTemplate(body, RequestOptions.none());
  }

  /**
   * Get a WhatsApp template.
   *
   * <p>{@code GET /v1/whatsapp/templates/{whatsapp_template_id}}
   *
   * @param whatsappTemplateId the {@code whatsapp_template_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getWhatsappTemplate(String whatsappTemplateId, RequestOptions options) {
    return requester.json(GET_WHATSAPP_TEMPLATE, List.of(whatsappTemplateId), null, null, options);
  }

  /**
   * Get a WhatsApp template.
   *
   * <p>{@code GET /v1/whatsapp/templates/{whatsapp_template_id}}
   *
   * @param whatsappTemplateId the {@code whatsapp_template_id} path parameter
   * @return the response body
   */
  public JsonNode getWhatsappTemplate(String whatsappTemplateId) {
    return getWhatsappTemplate(whatsappTemplateId, RequestOptions.none());
  }

  /**
   * List provider accounts.
   *
   * <p>{@code GET /v1/provider_accounts}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listProviderAccounts(ListProviderAccountsParams params, RequestOptions options) {
    return requester.page(LIST_PROVIDER_ACCOUNTS, List.of(), params, options);
  }

  /**
   * List provider accounts.
   *
   * <p>{@code GET /v1/provider_accounts}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listProviderAccounts() {
    return listProviderAccounts(null, RequestOptions.none());
  }

  /**
   * Get a provider account.
   *
   * <p>{@code GET /v1/provider_accounts/{provider_account_id}}
   *
   * @param providerAccountId the {@code provider_account_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getProviderAccount(String providerAccountId, RequestOptions options) {
    return requester.json(GET_PROVIDER_ACCOUNT, List.of(providerAccountId), null, null, options);
  }

  /**
   * Get a provider account.
   *
   * <p>{@code GET /v1/provider_accounts/{provider_account_id}}
   *
   * @param providerAccountId the {@code provider_account_id} path parameter
   * @return the response body
   */
  public JsonNode getProviderAccount(String providerAccountId) {
    return getProviderAccount(providerAccountId, RequestOptions.none());
  }

  /**
   * Update a provider account.
   *
   * <p>{@code PATCH /v1/provider_accounts/{provider_account_id}}
   *
   * @param providerAccountId the {@code provider_account_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode updateProviderAccount(
      String providerAccountId, JsonNode body, RequestOptions options) {
    return requester.json(UPDATE_PROVIDER_ACCOUNT, List.of(providerAccountId), null, body, options);
  }

  /**
   * Update a provider account.
   *
   * <p>{@code PATCH /v1/provider_accounts/{provider_account_id}}
   *
   * @param providerAccountId the {@code provider_account_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode updateProviderAccount(String providerAccountId, JsonNode body) {
    return updateProviderAccount(providerAccountId, body, RequestOptions.none());
  }

  /**
   * Verify a provider account.
   *
   * <p>{@code POST /v1/provider_accounts/{provider_account_id}/verify}
   *
   * @param providerAccountId the {@code provider_account_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode verifyProviderAccount(String providerAccountId, RequestOptions options) {
    return requester.json(VERIFY_PROVIDER_ACCOUNT, List.of(providerAccountId), null, null, options);
  }

  /**
   * Verify a provider account.
   *
   * <p>{@code POST /v1/provider_accounts/{provider_account_id}/verify}
   *
   * @param providerAccountId the {@code provider_account_id} path parameter
   * @return the response body
   */
  public JsonNode verifyProviderAccount(String providerAccountId) {
    return verifyProviderAccount(providerAccountId, RequestOptions.none());
  }

  /**
   * Get the status of a provider account.
   *
   * <p>{@code GET /v1/provider_accounts/{provider_account_id}/status}
   *
   * @param providerAccountId the {@code provider_account_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getProviderAccountStatus(String providerAccountId, RequestOptions options) {
    return requester.json(
        GET_PROVIDER_ACCOUNT_STATUS, List.of(providerAccountId), null, null, options);
  }

  /**
   * Get the status of a provider account.
   *
   * <p>{@code GET /v1/provider_accounts/{provider_account_id}/status}
   *
   * @param providerAccountId the {@code provider_account_id} path parameter
   * @return the response body
   */
  public JsonNode getProviderAccountStatus(String providerAccountId) {
    return getProviderAccountStatus(providerAccountId, RequestOptions.none());
  }

  /**
   * Check the sending domains of an e-mail provider account.
   *
   * <p>{@code GET /v1/provider_accounts/{provider_account_id}/email_domains}
   *
   * @param providerAccountId the {@code provider_account_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getProviderAccountEmailDomains(String providerAccountId, RequestOptions options) {
    return requester.json(
        GET_PROVIDER_ACCOUNT_EMAIL_DOMAINS, List.of(providerAccountId), null, null, options);
  }

  /**
   * Check the sending domains of an e-mail provider account.
   *
   * <p>{@code GET /v1/provider_accounts/{provider_account_id}/email_domains}
   *
   * @param providerAccountId the {@code provider_account_id} path parameter
   * @return the response body
   */
  public JsonNode getProviderAccountEmailDomains(String providerAccountId) {
    return getProviderAccountEmailDomains(providerAccountId, RequestOptions.none());
  }

  /**
   * List the e-mail warm-up plans.
   *
   * <p>{@code GET /v1/email_warmup_plans}
   *
   * @param options the request options
   * @return the response body
   */
  public JsonNode listEmailWarmupPlans(RequestOptions options) {
    return requester.json(LIST_EMAIL_WARMUP_PLANS, List.of(), null, null, options);
  }

  /**
   * List the e-mail warm-up plans.
   *
   * <p>{@code GET /v1/email_warmup_plans}
   *
   * @return the response body
   */
  public JsonNode listEmailWarmupPlans() {
    return listEmailWarmupPlans(RequestOptions.none());
  }

  /**
   * Quote the cost of a paid channel.
   *
   * <p>{@code GET /v1/channel_costs}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode quoteChannelCost(QuoteChannelCostParams params, RequestOptions options) {
    return requester.json(QUOTE_CHANNEL_COST, List.of(), params, null, options);
  }

  /**
   * Quote the cost of a paid channel.
   *
   * <p>{@code GET /v1/channel_costs}
   *
   * @param params the query parameters
   * @return the response body
   */
  public JsonNode quoteChannelCost(QuoteChannelCostParams params) {
    return quoteChannelCost(params, RequestOptions.none());
  }

  /**
   * List provider invoices.
   *
   * <p>{@code GET /v1/provider_invoices}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listProviderInvoices(ListProviderInvoicesParams params, RequestOptions options) {
    return requester.page(LIST_PROVIDER_INVOICES, List.of(), params, options);
  }

  /**
   * List provider invoices.
   *
   * <p>{@code GET /v1/provider_invoices}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listProviderInvoices() {
    return listProviderInvoices(null, RequestOptions.none());
  }

  /**
   * Record a provider invoice.
   *
   * <p>{@code POST /v1/provider_invoices}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createProviderInvoice(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_PROVIDER_INVOICE, List.of(), null, body, options);
  }

  /**
   * Record a provider invoice.
   *
   * <p>{@code POST /v1/provider_invoices}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createProviderInvoice(JsonNode body) {
    return createProviderInvoice(body, RequestOptions.none());
  }

  /**
   * Get a provider invoice.
   *
   * <p>{@code GET /v1/provider_invoices/{provider_invoice_id}}
   *
   * @param providerInvoiceId the {@code provider_invoice_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getProviderInvoice(String providerInvoiceId, RequestOptions options) {
    return requester.json(GET_PROVIDER_INVOICE, List.of(providerInvoiceId), null, null, options);
  }

  /**
   * Get a provider invoice.
   *
   * <p>{@code GET /v1/provider_invoices/{provider_invoice_id}}
   *
   * @param providerInvoiceId the {@code provider_invoice_id} path parameter
   * @return the response body
   */
  public JsonNode getProviderInvoice(String providerInvoiceId) {
    return getProviderInvoice(providerInvoiceId, RequestOptions.none());
  }

  /**
   * List raw data exports.
   *
   * <p>{@code GET /v1/exports}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listExports(ListExportsParams params, RequestOptions options) {
    return requester.page(LIST_EXPORTS, List.of(), params, options);
  }

  /**
   * List raw data exports.
   *
   * <p>{@code GET /v1/exports}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listExports() {
    return listExports(null, RequestOptions.none());
  }

  /**
   * Request a raw data export.
   *
   * <p>{@code POST /v1/exports}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createExport(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_EXPORT, List.of(), null, body, options);
  }

  /**
   * Request a raw data export.
   *
   * <p>{@code POST /v1/exports}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createExport(JsonNode body) {
    return createExport(body, RequestOptions.none());
  }

  /**
   * Get a raw data export.
   *
   * <p>{@code GET /v1/exports/{export_id}}
   *
   * @param exportId the {@code export_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getExport(String exportId, RequestOptions options) {
    return requester.json(GET_EXPORT, List.of(exportId), null, null, options);
  }

  /**
   * Get a raw data export.
   *
   * <p>{@code GET /v1/exports/{export_id}}
   *
   * @param exportId the {@code export_id} path parameter
   * @return the response body
   */
  public JsonNode getExport(String exportId) {
    return getExport(exportId, RequestOptions.none());
  }

  /**
   * List campaigns.
   *
   * <p>{@code GET /v1/campaigns}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listCampaigns(ListCampaignsParams params, RequestOptions options) {
    return requester.page(LIST_CAMPAIGNS, List.of(), params, options);
  }

  /**
   * List campaigns.
   *
   * <p>{@code GET /v1/campaigns}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listCampaigns() {
    return listCampaigns(null, RequestOptions.none());
  }

  /**
   * Create a campaign.
   *
   * <p>{@code POST /v1/campaigns}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createCampaign(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_CAMPAIGN, List.of(), null, body, options);
  }

  /**
   * Create a campaign.
   *
   * <p>{@code POST /v1/campaigns}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createCampaign(JsonNode body) {
    return createCampaign(body, RequestOptions.none());
  }

  /**
   * Get a campaign.
   *
   * <p>{@code GET /v1/campaigns/{campaign_id}}
   *
   * @param campaignId the {@code campaign_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getCampaign(String campaignId, RequestOptions options) {
    return requester.json(GET_CAMPAIGN, List.of(campaignId), null, null, options);
  }

  /**
   * Get a campaign.
   *
   * <p>{@code GET /v1/campaigns/{campaign_id}}
   *
   * @param campaignId the {@code campaign_id} path parameter
   * @return the response body
   */
  public JsonNode getCampaign(String campaignId) {
    return getCampaign(campaignId, RequestOptions.none());
  }

  /**
   * Add recipients to a campaign.
   *
   * <p>{@code POST /v1/campaigns/{campaign_id}/recipients}
   *
   * @param campaignId the {@code campaign_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode addCampaignRecipients(String campaignId, JsonNode body, RequestOptions options) {
    return requester.json(ADD_CAMPAIGN_RECIPIENTS, List.of(campaignId), null, body, options);
  }

  /**
   * Add recipients to a campaign.
   *
   * <p>{@code POST /v1/campaigns/{campaign_id}/recipients}
   *
   * @param campaignId the {@code campaign_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode addCampaignRecipients(String campaignId, JsonNode body) {
    return addCampaignRecipients(campaignId, body, RequestOptions.none());
  }

  /**
   * Prepare a campaign.
   *
   * <p>{@code POST /v1/campaigns/{campaign_id}/prepare}
   *
   * @param campaignId the {@code campaign_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode prepareCampaign(String campaignId, RequestOptions options) {
    return requester.json(PREPARE_CAMPAIGN, List.of(campaignId), null, null, options);
  }

  /**
   * Prepare a campaign.
   *
   * <p>{@code POST /v1/campaigns/{campaign_id}/prepare}
   *
   * @param campaignId the {@code campaign_id} path parameter
   * @return the response body
   */
  public JsonNode prepareCampaign(String campaignId) {
    return prepareCampaign(campaignId, RequestOptions.none());
  }

  /**
   * Render the samples of a campaign.
   *
   * <p>{@code GET /v1/campaigns/{campaign_id}/samples}
   *
   * @param campaignId the {@code campaign_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getCampaignSamples(String campaignId, RequestOptions options) {
    return requester.json(GET_CAMPAIGN_SAMPLES, List.of(campaignId), null, null, options);
  }

  /**
   * Render the samples of a campaign.
   *
   * <p>{@code GET /v1/campaigns/{campaign_id}/samples}
   *
   * @param campaignId the {@code campaign_id} path parameter
   * @return the response body
   */
  public JsonNode getCampaignSamples(String campaignId) {
    return getCampaignSamples(campaignId, RequestOptions.none());
  }

  /**
   * Approve the samples of a campaign.
   *
   * <p>{@code POST /v1/campaigns/{campaign_id}/approve_samples}
   *
   * @param campaignId the {@code campaign_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode approveCampaignSamples(String campaignId, JsonNode body, RequestOptions options) {
    return requester.json(APPROVE_CAMPAIGN_SAMPLES, List.of(campaignId), null, body, options);
  }

  /**
   * Approve the samples of a campaign.
   *
   * <p>{@code POST /v1/campaigns/{campaign_id}/approve_samples}
   *
   * @param campaignId the {@code campaign_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode approveCampaignSamples(String campaignId, JsonNode body) {
    return approveCampaignSamples(campaignId, body, RequestOptions.none());
  }

  /**
   * Trigger a campaign.
   *
   * <p>{@code POST /v1/campaigns/{campaign_id}/trigger}
   *
   * @param campaignId the {@code campaign_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode triggerCampaign(String campaignId, RequestOptions options) {
    return requester.json(TRIGGER_CAMPAIGN, List.of(campaignId), null, null, options);
  }

  /**
   * Trigger a campaign.
   *
   * <p>{@code POST /v1/campaigns/{campaign_id}/trigger}
   *
   * @param campaignId the {@code campaign_id} path parameter
   * @return the response body
   */
  public JsonNode triggerCampaign(String campaignId) {
    return triggerCampaign(campaignId, RequestOptions.none());
  }

  /**
   * Cancel a campaign.
   *
   * <p>{@code POST /v1/campaigns/{campaign_id}/cancel}
   *
   * @param campaignId the {@code campaign_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode cancelCampaign(String campaignId, JsonNode body, RequestOptions options) {
    return requester.json(CANCEL_CAMPAIGN, List.of(campaignId), null, body, options);
  }

  /**
   * Cancel a campaign.
   *
   * <p>{@code POST /v1/campaigns/{campaign_id}/cancel}
   *
   * @param campaignId the {@code campaign_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode cancelCampaign(String campaignId, JsonNode body) {
    return cancelCampaign(campaignId, body, RequestOptions.none());
  }

  /**
   * Get the delivery report.
   *
   * <p>{@code GET /v1/reports/deliveries}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode getDeliveryReport(GetDeliveryReportParams params, RequestOptions options) {
    return requester.json(GET_DELIVERY_REPORT, List.of(), params, null, options);
  }

  /**
   * Get the delivery report.
   *
   * <p>{@code GET /v1/reports/deliveries}
   *
   * @param params the query parameters
   * @return the response body
   */
  public JsonNode getDeliveryReport(GetDeliveryReportParams params) {
    return getDeliveryReport(params, RequestOptions.none());
  }

  /**
   * Get the skip distribution.
   *
   * <p>{@code GET /v1/reports/skips}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode getSkipReport(GetSkipReportParams params, RequestOptions options) {
    return requester.json(GET_SKIP_REPORT, List.of(), params, null, options);
  }

  /**
   * Get the skip distribution.
   *
   * <p>{@code GET /v1/reports/skips}
   *
   * @param params the query parameters
   * @return the response body
   */
  public JsonNode getSkipReport(GetSkipReportParams params) {
    return getSkipReport(params, RequestOptions.none());
  }

  /**
   * Get the cost report.
   *
   * <p>{@code GET /v1/reports/costs}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode getCostReport(GetCostReportParams params, RequestOptions options) {
    return requester.json(GET_COST_REPORT, List.of(), params, null, options);
  }

  /**
   * Get the cost report.
   *
   * <p>{@code GET /v1/reports/costs}
   *
   * @param params the query parameters
   * @return the response body
   */
  public JsonNode getCostReport(GetCostReportParams params) {
    return getCostReport(params, RequestOptions.none());
  }

  /**
   * List sender identities.
   *
   * <p>{@code GET /v1/sender_identities}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listSenderIdentities(ListSenderIdentitiesParams params, RequestOptions options) {
    return requester.page(LIST_SENDER_IDENTITIES, List.of(), params, options);
  }

  /**
   * List sender identities.
   *
   * <p>{@code GET /v1/sender_identities}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listSenderIdentities() {
    return listSenderIdentities(null, RequestOptions.none());
  }

  /**
   * Create a sender identity.
   *
   * <p>{@code POST /v1/sender_identities}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createSenderIdentity(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_SENDER_IDENTITY, List.of(), null, body, options);
  }

  /**
   * Create a sender identity.
   *
   * <p>{@code POST /v1/sender_identities}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createSenderIdentity(JsonNode body) {
    return createSenderIdentity(body, RequestOptions.none());
  }

  /**
   * Get a sender identity.
   *
   * <p>{@code GET /v1/sender_identities/{sender_identity_id}}
   *
   * @param senderIdentityId the {@code sender_identity_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getSenderIdentity(String senderIdentityId, RequestOptions options) {
    return requester.json(GET_SENDER_IDENTITY, List.of(senderIdentityId), null, null, options);
  }

  /**
   * Get a sender identity.
   *
   * <p>{@code GET /v1/sender_identities/{sender_identity_id}}
   *
   * @param senderIdentityId the {@code sender_identity_id} path parameter
   * @return the response body
   */
  public JsonNode getSenderIdentity(String senderIdentityId) {
    return getSenderIdentity(senderIdentityId, RequestOptions.none());
  }

  /**
   * Update a sender identity.
   *
   * <p>{@code PATCH /v1/sender_identities/{sender_identity_id}}
   *
   * @param senderIdentityId the {@code sender_identity_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode updateSenderIdentity(
      String senderIdentityId, JsonNode body, RequestOptions options) {
    return requester.json(UPDATE_SENDER_IDENTITY, List.of(senderIdentityId), null, body, options);
  }

  /**
   * Update a sender identity.
   *
   * <p>{@code PATCH /v1/sender_identities/{sender_identity_id}}
   *
   * @param senderIdentityId the {@code sender_identity_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode updateSenderIdentity(String senderIdentityId, JsonNode body) {
    return updateSenderIdentity(senderIdentityId, body, RequestOptions.none());
  }

  /**
   * Archive a sender identity.
   *
   * <p>{@code POST /v1/sender_identities/{sender_identity_id}/archive}
   *
   * @param senderIdentityId the {@code sender_identity_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode archiveSenderIdentity(String senderIdentityId, RequestOptions options) {
    return requester.json(ARCHIVE_SENDER_IDENTITY, List.of(senderIdentityId), null, null, options);
  }

  /**
   * Archive a sender identity.
   *
   * <p>{@code POST /v1/sender_identities/{sender_identity_id}/archive}
   *
   * @param senderIdentityId the {@code sender_identity_id} path parameter
   * @return the response body
   */
  public JsonNode archiveSenderIdentity(String senderIdentityId) {
    return archiveSenderIdentity(senderIdentityId, RequestOptions.none());
  }

  /**
   * List channel identities.
   *
   * <p>{@code GET /v1/channel_identities}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listChannelIdentities(ListChannelIdentitiesParams params, RequestOptions options) {
    return requester.page(LIST_CHANNEL_IDENTITIES, List.of(), params, options);
  }

  /**
   * List channel identities.
   *
   * <p>{@code GET /v1/channel_identities}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listChannelIdentities() {
    return listChannelIdentities(null, RequestOptions.none());
  }

  /**
   * Get a channel identity.
   *
   * <p>{@code GET /v1/channel_identities/{channel_identity_id}}
   *
   * @param channelIdentityId the {@code channel_identity_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getChannelIdentity(String channelIdentityId, RequestOptions options) {
    return requester.json(GET_CHANNEL_IDENTITY, List.of(channelIdentityId), null, null, options);
  }

  /**
   * Get a channel identity.
   *
   * <p>{@code GET /v1/channel_identities/{channel_identity_id}}
   *
   * @param channelIdentityId the {@code channel_identity_id} path parameter
   * @return the response body
   */
  public JsonNode getChannelIdentity(String channelIdentityId) {
    return getChannelIdentity(channelIdentityId, RequestOptions.none());
  }

  /**
   * Update a channel identity.
   *
   * <p>{@code PATCH /v1/channel_identities/{channel_identity_id}}
   *
   * @param channelIdentityId the {@code channel_identity_id} path parameter
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode updateChannelIdentity(
      String channelIdentityId, JsonNode body, RequestOptions options) {
    return requester.json(UPDATE_CHANNEL_IDENTITY, List.of(channelIdentityId), null, body, options);
  }

  /**
   * Update a channel identity.
   *
   * <p>{@code PATCH /v1/channel_identities/{channel_identity_id}}
   *
   * @param channelIdentityId the {@code channel_identity_id} path parameter
   * @param body the request body
   * @return the response body
   */
  public JsonNode updateChannelIdentity(String channelIdentityId, JsonNode body) {
    return updateChannelIdentity(channelIdentityId, body, RequestOptions.none());
  }

  /**
   * Retire a channel identity.
   *
   * <p>{@code POST /v1/channel_identities/{channel_identity_id}/archive}
   *
   * @param channelIdentityId the {@code channel_identity_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode archiveChannelIdentity(String channelIdentityId, RequestOptions options) {
    return requester.json(
        ARCHIVE_CHANNEL_IDENTITY, List.of(channelIdentityId), null, null, options);
  }

  /**
   * Retire a channel identity.
   *
   * <p>{@code POST /v1/channel_identities/{channel_identity_id}/archive}
   *
   * @param channelIdentityId the {@code channel_identity_id} path parameter
   * @return the response body
   */
  public JsonNode archiveChannelIdentity(String channelIdentityId) {
    return archiveChannelIdentity(channelIdentityId, RequestOptions.none());
  }

  /**
   * Upload a DMARC aggregate or TLS report.
   *
   * <p>{@code POST /v1/email_reports}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode uploadEmailReport(JsonNode body, RequestOptions options) {
    return requester.json(UPLOAD_EMAIL_REPORT, List.of(), null, body, options);
  }

  /**
   * Upload a DMARC aggregate or TLS report.
   *
   * <p>{@code POST /v1/email_reports}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode uploadEmailReport(JsonNode body) {
    return uploadEmailReport(body, RequestOptions.none());
  }

  /**
   * Summarize a domain's DMARC and TLS reports.
   *
   * <p>{@code GET /v1/email_reports/summary}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the response body
   */
  public JsonNode getEmailReportSummary(
      GetEmailReportSummaryParams params, RequestOptions options) {
    return requester.json(GET_EMAIL_REPORT_SUMMARY, List.of(), params, null, options);
  }

  /**
   * Summarize a domain's DMARC and TLS reports.
   *
   * <p>{@code GET /v1/email_reports/summary}
   *
   * @param params the query parameters
   * @return the response body
   */
  public JsonNode getEmailReportSummary(GetEmailReportSummaryParams params) {
    return getEmailReportSummary(params, RequestOptions.none());
  }

  /**
   * List recurrence rules.
   *
   * <p>{@code GET /v1/recurrences}
   *
   * @param params the query parameters
   * @param options the request options
   * @return the first page; further pages are fetched lazily
   */
  public Page listRecurrences(ListRecurrencesParams params, RequestOptions options) {
    return requester.page(LIST_RECURRENCES, List.of(), params, options);
  }

  /**
   * List recurrence rules.
   *
   * <p>{@code GET /v1/recurrences}
   *
   * @return the first page; further pages are fetched lazily
   */
  public Page listRecurrences() {
    return listRecurrences(null, RequestOptions.none());
  }

  /**
   * Define a recurrence rule.
   *
   * <p>{@code POST /v1/recurrences}
   *
   * @param body the request body
   * @param options the request options
   * @return the response body
   */
  public JsonNode createRecurrence(JsonNode body, RequestOptions options) {
    return requester.json(CREATE_RECURRENCE, List.of(), null, body, options);
  }

  /**
   * Define a recurrence rule.
   *
   * <p>{@code POST /v1/recurrences}
   *
   * @param body the request body
   * @return the response body
   */
  public JsonNode createRecurrence(JsonNode body) {
    return createRecurrence(body, RequestOptions.none());
  }

  /**
   * Get a recurrence rule.
   *
   * <p>{@code GET /v1/recurrences/{recurrence_id}}
   *
   * @param recurrenceId the {@code recurrence_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode getRecurrence(String recurrenceId, RequestOptions options) {
    return requester.json(GET_RECURRENCE, List.of(recurrenceId), null, null, options);
  }

  /**
   * Get a recurrence rule.
   *
   * <p>{@code GET /v1/recurrences/{recurrence_id}}
   *
   * @param recurrenceId the {@code recurrence_id} path parameter
   * @return the response body
   */
  public JsonNode getRecurrence(String recurrenceId) {
    return getRecurrence(recurrenceId, RequestOptions.none());
  }

  /**
   * Cancel a recurrence rule.
   *
   * <p>{@code POST /v1/recurrences/{recurrence_id}/cancel}
   *
   * @param recurrenceId the {@code recurrence_id} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode cancelRecurrence(String recurrenceId, RequestOptions options) {
    return requester.json(CANCEL_RECURRENCE, List.of(recurrenceId), null, null, options);
  }

  /**
   * Cancel a recurrence rule.
   *
   * <p>{@code POST /v1/recurrences/{recurrence_id}/cancel}
   *
   * @param recurrenceId the {@code recurrence_id} path parameter
   * @return the response body
   */
  public JsonNode cancelRecurrence(String recurrenceId) {
    return cancelRecurrence(recurrenceId, RequestOptions.none());
  }

  /**
   * Reset an active throttle.
   *
   * <p>{@code POST /v1/throttles/{throttle_key}/reset}
   *
   * @param throttleKey the {@code throttle_key} path parameter
   * @param options the request options
   * @return the response body
   */
  public JsonNode resetThrottle(String throttleKey, RequestOptions options) {
    return requester.json(RESET_THROTTLE, List.of(throttleKey), null, null, options);
  }

  /**
   * Reset an active throttle.
   *
   * <p>{@code POST /v1/throttles/{throttle_key}/reset}
   *
   * @param throttleKey the {@code throttle_key} path parameter
   * @return the response body
   */
  public JsonNode resetThrottle(String throttleKey) {
    return resetThrottle(throttleKey, RequestOptions.none());
  }
}
