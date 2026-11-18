package app.suiss.relay.params;

/** Query parameters of {@code listWebhookEventTypes}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListWebhookEventTypesParams extends QueryParams<ListWebhookEventTypesParams> {
  /** Creates an empty parameter set. */
  public ListWebhookEventTypesParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEventTypesParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEventTypesParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEventTypesParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code state}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookEventTypesParams state(String value) {
    return set("state", value);
  }

  @Override
  protected ListWebhookEventTypesParams self() {
    return this;
  }
}
