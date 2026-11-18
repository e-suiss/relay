package app.suiss.relay.params;

/** Query parameters of {@code getTemplate}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetTemplateParams extends QueryParams<GetTemplateParams> {
  /** Creates an empty parameter set. */
  public GetTemplateParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public GetTemplateParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected GetTemplateParams self() {
    return this;
  }
}
