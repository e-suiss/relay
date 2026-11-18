package app.suiss.relay.params;

/** Query parameters of {@code promoteLayoutVersion}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class PromoteLayoutVersionParams extends QueryParams<PromoteLayoutVersionParams> {
  /** Creates an empty parameter set. */
  public PromoteLayoutVersionParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public PromoteLayoutVersionParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected PromoteLayoutVersionParams self() {
    return this;
  }
}
