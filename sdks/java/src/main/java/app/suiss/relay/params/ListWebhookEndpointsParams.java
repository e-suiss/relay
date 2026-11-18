package app.suiss.relay.params;

/** Query parameters of {@code listWebhookEndpoints}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListWebhookEndpointsParams extends QueryParams<ListWebhookEndpointsParams> {
  /** Creates an empty parameter set. */
  public ListWebhookEndpointsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEndpointsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEndpointsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEndpointsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code use}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEndpointsParams use(String value) {
    return set("use", value);
  }

  /**
   * Sets {@code state}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEndpointsParams state(String value) {
    return set("state", value);
  }

  /**
   * Sets {@code consumer_id}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEndpointsParams consumerId(String value) {
    return set("consumer_id", value);
  }

  @Override
  protected ListWebhookEndpointsParams self() {
    return this;
  }
}
