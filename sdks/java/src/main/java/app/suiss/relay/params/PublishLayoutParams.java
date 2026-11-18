package app.suiss.relay.params;

/** Query parameters of {@code publishLayout}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class PublishLayoutParams extends QueryParams<PublishLayoutParams> {
  /** Creates an empty parameter set. */
  public PublishLayoutParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public PublishLayoutParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected PublishLayoutParams self() {
    return this;
  }
}
