package app.suiss.relay.params;

/** Query parameters of {@code listSenderIdentities}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListSenderIdentitiesParams extends QueryParams<ListSenderIdentitiesParams> {
  /** Creates an empty parameter set. */
  public ListSenderIdentitiesParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSenderIdentitiesParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSenderIdentitiesParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListSenderIdentitiesParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListSenderIdentitiesParams self() {
    return this;
  }
}
