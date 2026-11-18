package app.suiss.relay.params;

/** Query parameters of {@code promotePartialVersion}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class PromotePartialVersionParams extends QueryParams<PromotePartialVersionParams> {
  /** Creates an empty parameter set. */
  public PromotePartialVersionParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public PromotePartialVersionParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected PromotePartialVersionParams self() {
    return this;
  }
}
