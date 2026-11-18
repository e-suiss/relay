package app.suiss.relay.params;

/** Query parameters of {@code listWebhookEvents}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListWebhookEventsParams extends QueryParams<ListWebhookEventsParams> {
  /** Creates an empty parameter set. */
  public ListWebhookEventsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEventsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEventsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEventsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code event_type}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEventsParams eventType(String value) {
    return set("event_type", value);
  }

  /**
   * Sets {@code created_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEventsParams createdAfter(String value) {
    return set("created_after", value);
  }

  @Override
  protected ListWebhookEventsParams self() {
    return this;
  }
}
