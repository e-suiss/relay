package app.suiss.relay.params;

/** Query parameters of {@code listWaitpoints}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListWaitpointsParams extends QueryParams<ListWaitpointsParams> {
  /** Creates an empty parameter set. */
  public ListWaitpointsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWaitpointsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWaitpointsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWaitpointsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code state}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWaitpointsParams state(String value) {
    return set("state", value);
  }

  /**
   * Sets {@code awaiting_response}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWaitpointsParams awaitingResponse(boolean value) {
    return set("awaiting_response", Boolean.toString(value));
  }

  /**
   * Sets {@code waiter}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWaitpointsParams waiter(String value) {
    return set("waiter", value);
  }

  /**
   * Sets {@code tag}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWaitpointsParams tag(String value) {
    return set("tag", value);
  }

  @Override
  protected ListWaitpointsParams self() {
    return this;
  }
}
