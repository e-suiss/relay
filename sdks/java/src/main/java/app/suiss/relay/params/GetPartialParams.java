package app.suiss.relay.params;

/** Query parameters of {@code getPartial}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetPartialParams extends QueryParams<GetPartialParams> {
  /** Creates an empty parameter set. */
  public GetPartialParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public GetPartialParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected GetPartialParams self() {
    return this;
  }
}
