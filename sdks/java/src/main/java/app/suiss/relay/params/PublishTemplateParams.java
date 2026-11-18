package app.suiss.relay.params;

/** Query parameters of {@code publishTemplate}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class PublishTemplateParams extends QueryParams<PublishTemplateParams> {
  /** Creates an empty parameter set. */
  public PublishTemplateParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public PublishTemplateParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected PublishTemplateParams self() {
    return this;
  }
}
