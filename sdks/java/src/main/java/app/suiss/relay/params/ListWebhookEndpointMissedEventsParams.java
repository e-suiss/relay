package app.suiss.relay.params;

/** Query parameters of {@code listWebhookEndpointMissedEvents}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListWebhookEndpointMissedEventsParams
    extends QueryParams<ListWebhookEndpointMissedEventsParams> {
  /** Creates an empty parameter set. */
  public ListWebhookEndpointMissedEventsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEndpointMissedEventsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEndpointMissedEventsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEndpointMissedEventsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code event_type}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEndpointMissedEventsParams eventType(String value) {
    return set("event_type", value);
  }

  /**
   * Sets {@code created_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEndpointMissedEventsParams createdAfter(String value) {
    return set("created_after", value);
  }

  /**
   * Sets {@code created_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEndpointMissedEventsParams createdBefore(String value) {
    return set("created_before", value);
  }

  @Override
  protected ListWebhookEndpointMissedEventsParams self() {
    return this;
  }
}
