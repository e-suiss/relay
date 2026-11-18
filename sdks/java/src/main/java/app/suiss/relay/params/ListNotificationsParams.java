package app.suiss.relay.params;

/** Query parameters of {@code listNotifications}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListNotificationsParams extends QueryParams<ListNotificationsParams> {
  /** Creates an empty parameter set. */
  public ListNotificationsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListNotificationsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListNotificationsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListNotificationsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code subscriber}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListNotificationsParams subscriber(String value) {
    return set("subscriber", value);
  }

  /**
   * Sets {@code workflow}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListNotificationsParams workflow(String value) {
    return set("workflow", value);
  }

  /**
   * Sets {@code status}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListNotificationsParams status(String value) {
    return set("status", value);
  }

  /**
   * Sets {@code created_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListNotificationsParams createdAfter(String value) {
    return set("created_after", value);
  }

  /**
   * Sets {@code created_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListNotificationsParams createdBefore(String value) {
    return set("created_before", value);
  }

  /**
   * Sets {@code is_test}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListNotificationsParams isTest(boolean value) {
    return set("is_test", Boolean.toString(value));
  }

  @Override
  protected ListNotificationsParams self() {
    return this;
  }
}
