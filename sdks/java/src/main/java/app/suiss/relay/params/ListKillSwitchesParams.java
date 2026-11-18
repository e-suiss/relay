package app.suiss.relay.params;

/** Query parameters of {@code listKillSwitches}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListKillSwitchesParams extends QueryParams<ListKillSwitchesParams> {
  /** Creates an empty parameter set. */
  public ListKillSwitchesParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListKillSwitchesParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListKillSwitchesParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListKillSwitchesParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code include_released}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListKillSwitchesParams includeReleased(boolean value) {
    return set("include_released", Boolean.toString(value));
  }

  @Override
  protected ListKillSwitchesParams self() {
    return this;
  }
}
