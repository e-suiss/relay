package app.suiss.relay.params;

/** Query parameters of {@code listSubscriberDevices}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListSubscriberDevicesParams extends QueryParams<ListSubscriberDevicesParams> {
  /** Creates an empty parameter set. */
  public ListSubscriberDevicesParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubscriberDevicesParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubscriberDevicesParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubscriberDevicesParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListSubscriberDevicesParams self() {
    return this;
  }
}
