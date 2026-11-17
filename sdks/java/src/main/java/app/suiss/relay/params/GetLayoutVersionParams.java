package app.suiss.relay.params;

/** Query parameters of {@code getLayoutVersion}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetLayoutVersionParams extends QueryParams<GetLayoutVersionParams> {
  /** Creates an empty parameter set. */
  public GetLayoutVersionParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public GetLayoutVersionParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected GetLayoutVersionParams self() {
    return this;
  }
}
