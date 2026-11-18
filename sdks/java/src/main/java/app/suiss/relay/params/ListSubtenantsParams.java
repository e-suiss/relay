package app.suiss.relay.params;

/** Query parameters of {@code listSubtenants}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListSubtenantsParams extends QueryParams<ListSubtenantsParams> {
  /** Creates an empty parameter set. */
  public ListSubtenantsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubtenantsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubtenantsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSubtenantsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListSubtenantsParams self() {
    return this;
  }
}
