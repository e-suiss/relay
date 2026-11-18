package app.suiss.relay.params;

/** Query parameters of {@code getVariantReport}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetVariantReportParams extends QueryParams<GetVariantReportParams> {
  /** Creates an empty parameter set. */
  public GetVariantReportParams() {}

  /**
   * Sets {@code from} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public GetVariantReportParams from(String value) {
    return set("from", value);
  }

  /**
   * Sets {@code to} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public GetVariantReportParams to(String value) {
    return set("to", value);
  }

  @Override
  protected GetVariantReportParams self() {
    return this;
  }
}
