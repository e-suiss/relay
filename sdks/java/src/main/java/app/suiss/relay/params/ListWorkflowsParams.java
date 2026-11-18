package app.suiss.relay.params;

/** Query parameters of {@code listWorkflows}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListWorkflowsParams extends QueryParams<ListWorkflowsParams> {
  /** Creates an empty parameter set. */
  public ListWorkflowsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWorkflowsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWorkflowsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWorkflowsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListWorkflowsParams self() {
    return this;
  }
}
