package app.suiss.relay.params;

/** Query parameters of {@code listTemplates}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListTemplatesParams extends QueryParams<ListTemplatesParams> {
  /** Creates an empty parameter set. */
  public ListTemplatesParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTemplatesParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTemplatesParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTemplatesParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTemplatesParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected ListTemplatesParams self() {
    return this;
  }
}
