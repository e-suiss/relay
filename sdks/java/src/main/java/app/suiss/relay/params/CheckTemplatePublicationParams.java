package app.suiss.relay.params;

/** Query parameters of {@code checkTemplatePublication}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class CheckTemplatePublicationParams
    extends QueryParams<CheckTemplatePublicationParams> {
  /** Creates an empty parameter set. */
  public CheckTemplatePublicationParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public CheckTemplatePublicationParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected CheckTemplatePublicationParams self() {
    return this;
  }
}
