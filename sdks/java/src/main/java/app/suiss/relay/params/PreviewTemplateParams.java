package app.suiss.relay.params;

/** Query parameters of {@code previewTemplate}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class PreviewTemplateParams extends QueryParams<PreviewTemplateParams> {
  /** Creates an empty parameter set. */
  public PreviewTemplateParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public PreviewTemplateParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected PreviewTemplateParams self() {
    return this;
  }
}
