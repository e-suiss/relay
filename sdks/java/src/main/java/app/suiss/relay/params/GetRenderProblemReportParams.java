package app.suiss.relay.params;

/** Query parameters of {@code getRenderProblemReport}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetRenderProblemReportParams extends QueryParams<GetRenderProblemReportParams> {
  /** Creates an empty parameter set. */
  public GetRenderProblemReportParams() {}

  /**
   * Sets {@code from} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public GetRenderProblemReportParams from(String value) {
    return set("from", value);
  }

  /**
   * Sets {@code to} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public GetRenderProblemReportParams to(String value) {
    return set("to", value);
  }

  @Override
  protected GetRenderProblemReportParams self() {
    return this;
  }
}
