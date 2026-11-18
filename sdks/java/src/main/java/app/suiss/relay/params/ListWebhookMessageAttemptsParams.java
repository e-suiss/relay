package app.suiss.relay.params;

/** Query parameters of {@code listWebhookMessageAttempts}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListWebhookMessageAttemptsParams
    extends QueryParams<ListWebhookMessageAttemptsParams> {
  /** Creates an empty parameter set. */
  public ListWebhookMessageAttemptsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookMessageAttemptsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookMessageAttemptsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookMessageAttemptsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListWebhookMessageAttemptsParams self() {
    return this;
  }
}
