package app.suiss.relay.params;

/** Query parameters of {@code replaceTemplateDraft}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ReplaceTemplateDraftParams extends QueryParams<ReplaceTemplateDraftParams> {
  /** Creates an empty parameter set. */
  public ReplaceTemplateDraftParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public ReplaceTemplateDraftParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected ReplaceTemplateDraftParams self() {
    return this;
  }
}
