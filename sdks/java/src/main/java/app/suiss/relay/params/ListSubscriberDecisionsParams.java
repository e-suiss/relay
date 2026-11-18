package app.suiss.relay.params;

/** Query parameters of {@code listSubscriberDecisions}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListSubscriberDecisionsParams
    extends QueryParams<ListSubscriberDecisionsParams> {
  /** Creates an empty parameter set. */
  public ListSubscriberDecisionsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubscriberDecisionsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubscriberDecisionsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubscriberDecisionsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code created_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubscriberDecisionsParams createdAfter(String value) {
    return set("created_after", value);
  }

  /**
   * Sets {@code created_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubscriberDecisionsParams createdBefore(String value) {
    return set("created_before", value);
  }

  /**
   * Sets {@code workflow}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubscriberDecisionsParams workflow(String value) {
    return set("workflow", value);
  }

  @Override
  protected ListSubscriberDecisionsParams self() {
    return this;
  }
}
