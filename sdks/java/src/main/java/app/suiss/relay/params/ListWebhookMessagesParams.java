package app.suiss.relay.params;

/** Query parameters of {@code listWebhookMessages}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListWebhookMessagesParams extends QueryParams<ListWebhookMessagesParams> {
  /** Creates an empty parameter set. */
  public ListWebhookMessagesParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookMessagesParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookMessagesParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookMessagesParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code endpoint_id}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookMessagesParams endpointId(String value) {
    return set("endpoint_id", value);
  }

  /**
   * Sets {@code event_id}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookMessagesParams eventId(String value) {
    return set("event_id", value);
  }

  /**
   * Sets {@code state}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookMessagesParams state(String value) {
    return set("state", value);
  }

  /**
   * Sets {@code event_type}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookMessagesParams eventType(String value) {
    return set("event_type", value);
  }

  /**
   * Sets {@code created_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookMessagesParams createdAfter(String value) {
    return set("created_after", value);
  }

  /**
   * Sets {@code created_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookMessagesParams createdBefore(String value) {
    return set("created_before", value);
  }

  @Override
  protected ListWebhookMessagesParams self() {
    return this;
  }
}
