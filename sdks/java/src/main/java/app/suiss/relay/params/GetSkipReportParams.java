package app.suiss.relay.params;

/** Query parameters of {@code getSkipReport}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetSkipReportParams extends QueryParams<GetSkipReportParams> {
  /** Creates an empty parameter set. */
  public GetSkipReportParams() {}

  /**
   * Sets {@code from} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public GetSkipReportParams from(String value) {
    return set("from", value);
  }

  /**
   * Sets {@code to} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public GetSkipReportParams to(String value) {
    return set("to", value);
  }

  @Override
  protected GetSkipReportParams self() {
    return this;
  }
}
