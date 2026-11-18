package app.suiss.relay.params;

/** Query parameters of {@code createTemplate}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class CreateTemplateParams extends QueryParams<CreateTemplateParams> {
  /** Creates an empty parameter set. */
  public CreateTemplateParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public CreateTemplateParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected CreateTemplateParams self() {
    return this;
  }
}
