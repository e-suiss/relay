package app.suiss.relay.params;

/** Query parameters of {@code getDeliveryReport}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetDeliveryReportParams extends QueryParams<GetDeliveryReportParams> {
  /** Creates an empty parameter set. */
  public GetDeliveryReportParams() {}

  /**
   * Sets {@code from} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public GetDeliveryReportParams from(String value) {
    return set("from", value);
  }

  /**
   * Sets {@code to} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public GetDeliveryReportParams to(String value) {
    return set("to", value);
  }

  @Override
  protected GetDeliveryReportParams self() {
    return this;
  }
}
