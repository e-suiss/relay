package app.suiss.relay.params;

/** Query parameters of {@code listWebhookSources}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListWebhookSourcesParams extends QueryParams<ListWebhookSourcesParams> {
  /** Creates an empty parameter set. */
  public ListWebhookSourcesParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookSourcesParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookSourcesParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookSourcesParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code state}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookSourcesParams state(String value) {
    return set("state", value);
  }

  @Override
  protected ListWebhookSourcesParams self() {
    return this;
  }
}
