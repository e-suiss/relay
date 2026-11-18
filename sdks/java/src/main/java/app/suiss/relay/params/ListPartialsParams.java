package app.suiss.relay.params;

/** Query parameters of {@code listPartials}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListPartialsParams extends QueryParams<ListPartialsParams> {
  /** Creates an empty parameter set. */
  public ListPartialsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListPartialsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListPartialsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListPartialsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListPartialsParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected ListPartialsParams self() {
    return this;
  }
}
