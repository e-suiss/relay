package app.suiss.relay.params;

/** Query parameters of {@code listTemplateVersions}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListTemplateVersionsParams extends QueryParams<ListTemplateVersionsParams> {
  /** Creates an empty parameter set. */
  public ListTemplateVersionsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTemplateVersionsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTemplateVersionsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTemplateVersionsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListTemplateVersionsParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected ListTemplateVersionsParams self() {
    return this;
  }
}
