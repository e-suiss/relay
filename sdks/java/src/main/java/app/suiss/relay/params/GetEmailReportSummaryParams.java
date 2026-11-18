package app.suiss.relay.params;

/** Query parameters of {@code getEmailReportSummary}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetEmailReportSummaryParams extends QueryParams<GetEmailReportSummaryParams> {
  /** Creates an empty parameter set. */
  public GetEmailReportSummaryParams() {}

  /**
   * Sets {@code domain} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public GetEmailReportSummaryParams domain(String value) {
    return set("domain", value);
  }

  /**
   * Sets {@code from}.
   *
   * @param value the value
   * @return these parameters
   */
  public GetEmailReportSummaryParams from(String value) {
    return set("from", value);
  }

  /**
   * Sets {@code to}.
   *
   * @param value the value
   * @return these parameters
   */
  public GetEmailReportSummaryParams to(String value) {
    return set("to", value);
  }

  @Override
  protected GetEmailReportSummaryParams self() {
    return this;
  }
}
