package app.suiss.relay.params;

/** Query parameters of {@code listChannelIdentities}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListChannelIdentitiesParams extends QueryParams<ListChannelIdentitiesParams> {
  /** Creates an empty parameter set. */
  public ListChannelIdentitiesParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListChannelIdentitiesParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListChannelIdentitiesParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListChannelIdentitiesParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListChannelIdentitiesParams self() {
    return this;
  }
}
