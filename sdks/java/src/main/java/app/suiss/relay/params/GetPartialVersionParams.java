package app.suiss.relay.params;

/** Query parameters of {@code getPartialVersion}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetPartialVersionParams extends QueryParams<GetPartialVersionParams> {
  /** Creates an empty parameter set. */
  public GetPartialVersionParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public GetPartialVersionParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected GetPartialVersionParams self() {
    return this;
  }
}
