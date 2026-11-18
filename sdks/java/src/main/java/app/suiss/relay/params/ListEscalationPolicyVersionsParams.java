package app.suiss.relay.params;

/** Query parameters of {@code listEscalationPolicyVersions}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListEscalationPolicyVersionsParams
    extends QueryParams<ListEscalationPolicyVersionsParams> {
  /** Creates an empty parameter set. */
  public ListEscalationPolicyVersionsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListEscalationPolicyVersionsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListEscalationPolicyVersionsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListEscalationPolicyVersionsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListEscalationPolicyVersionsParams self() {
    return this;
  }
}
