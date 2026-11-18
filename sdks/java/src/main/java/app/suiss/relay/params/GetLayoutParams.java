package app.suiss.relay.params;

/** Query parameters of {@code getLayout}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetLayoutParams extends QueryParams<GetLayoutParams> {
  /** Creates an empty parameter set. */
  public GetLayoutParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public GetLayoutParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected GetLayoutParams self() {
    return this;
  }
}
