package app.suiss.relay.params;

/** Query parameters of {@code listIysUploads}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListIysUploadsParams extends QueryParams<ListIysUploadsParams> {
  /** Creates an empty parameter set. */
  public ListIysUploadsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListIysUploadsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListIysUploadsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListIysUploadsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code state}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListIysUploadsParams state(String value) {
    return set("state", value);
  }

  @Override
  protected ListIysUploadsParams self() {
    return this;
  }
}
