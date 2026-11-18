package app.suiss.relay.params;

/** Query parameters of {@code publishPartial}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class PublishPartialParams extends QueryParams<PublishPartialParams> {
  /** Creates an empty parameter set. */
  public PublishPartialParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public PublishPartialParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected PublishPartialParams self() {
    return this;
  }
}
