package app.suiss.relay.params;

/** Query parameters of {@code getTemplateVersion}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetTemplateVersionParams extends QueryParams<GetTemplateVersionParams> {
  /** Creates an empty parameter set. */
  public GetTemplateVersionParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public GetTemplateVersionParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected GetTemplateVersionParams self() {
    return this;
  }
}
