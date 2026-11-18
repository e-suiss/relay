package app.suiss.relay.params;

/** Query parameters of {@code getBrand}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetBrandParams extends QueryParams<GetBrandParams> {
  /** Creates an empty parameter set. */
  public GetBrandParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public GetBrandParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected GetBrandParams self() {
    return this;
  }
}
