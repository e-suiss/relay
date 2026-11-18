package app.suiss.relay.params;

/** Query parameters of {@code updateBrand}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class UpdateBrandParams extends QueryParams<UpdateBrandParams> {
  /** Creates an empty parameter set. */
  public UpdateBrandParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public UpdateBrandParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected UpdateBrandParams self() {
    return this;
  }
}
