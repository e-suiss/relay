package app.suiss.relay.params;

/** Query parameters of {@code getFallbackTimezoneReport}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetFallbackTimezoneReportParams
    extends QueryParams<GetFallbackTimezoneReportParams> {
  /** Creates an empty parameter set. */
  public GetFallbackTimezoneReportParams() {}

  /**
   * Sets {@code from} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public GetFallbackTimezoneReportParams from(String value) {
    return set("from", value);
  }

  /**
   * Sets {@code to} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public GetFallbackTimezoneReportParams to(String value) {
    return set("to", value);
  }

  @Override
  protected GetFallbackTimezoneReportParams self() {
    return this;
  }
}
