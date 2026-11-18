package app.suiss.relay.params;

/** Query parameters of {@code listNotificationDeliveries}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListNotificationDeliveriesParams
    extends QueryParams<ListNotificationDeliveriesParams> {
  /** Creates an empty parameter set. */
  public ListNotificationDeliveriesParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListNotificationDeliveriesParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListNotificationDeliveriesParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListNotificationDeliveriesParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListNotificationDeliveriesParams self() {
    return this;
  }
}
