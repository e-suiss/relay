package app.suiss.relay.params;

/** Query parameters of {@code getCostReport}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetCostReportParams extends QueryParams<GetCostReportParams> {
  /** Creates an empty parameter set. */
  public GetCostReportParams() {}

  /**
   * Sets {@code from} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public GetCostReportParams from(String value) {
    return set("from", value);
  }

  /**
   * Sets {@code to} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public GetCostReportParams to(String value) {
    return set("to", value);
  }

  @Override
  protected GetCostReportParams self() {
    return this;
  }
}
