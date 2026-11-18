package app.suiss.relay.params;

/** Query parameters of {@code listWebhookEndpointVersions}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListWebhookEndpointVersionsParams
    extends QueryParams<ListWebhookEndpointVersionsParams> {
  /** Creates an empty parameter set. */
  public ListWebhookEndpointVersionsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEndpointVersionsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEndpointVersionsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEndpointVersionsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListWebhookEndpointVersionsParams self() {
    return this;
  }
}
