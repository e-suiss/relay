package app.suiss.relay.params;

/** Query parameters of {@code listWorkflowVersions}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListWorkflowVersionsParams extends QueryParams<ListWorkflowVersionsParams> {
  /** Creates an empty parameter set. */
  public ListWorkflowVersionsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWorkflowVersionsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWorkflowVersionsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWorkflowVersionsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListWorkflowVersionsParams self() {
    return this;
  }
}
