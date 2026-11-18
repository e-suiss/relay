package app.suiss.relay.params;

/** Query parameters of {@code listAgentCeilingHolds}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListAgentCeilingHoldsParams extends QueryParams<ListAgentCeilingHoldsParams> {
  /** Creates an empty parameter set. */
  public ListAgentCeilingHoldsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListAgentCeilingHoldsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListAgentCeilingHoldsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListAgentCeilingHoldsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code state}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListAgentCeilingHoldsParams state(String value) {
    return set("state", value);
  }

  @Override
  protected ListAgentCeilingHoldsParams self() {
    return this;
  }
}
