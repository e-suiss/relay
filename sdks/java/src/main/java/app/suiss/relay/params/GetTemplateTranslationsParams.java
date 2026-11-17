package app.suiss.relay.params;

/** Query parameters of {@code getTemplateTranslations}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetTemplateTranslationsParams
    extends QueryParams<GetTemplateTranslationsParams> {
  /** Creates an empty parameter set. */
  public GetTemplateTranslationsParams() {}

  /**
   * Sets {@code source}.
   *
   * @param value the value
   * @return these parameters
   */
  public GetTemplateTranslationsParams source(String value) {
    return set("source", value);
  }

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public GetTemplateTranslationsParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected GetTemplateTranslationsParams self() {
    return this;
  }
}
