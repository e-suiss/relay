package app.suiss.relay.params;

/** Query parameters of {@code listAgents}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListAgentsParams extends QueryParams<ListAgentsParams> {
  /** Creates an empty parameter set. */
  public ListAgentsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListAgentsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListAgentsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListAgentsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListAgentsParams self() {
    return this;
  }
}
