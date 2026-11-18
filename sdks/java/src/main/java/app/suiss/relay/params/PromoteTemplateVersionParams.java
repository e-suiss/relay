package app.suiss.relay.params;

/** Query parameters of {@code promoteTemplateVersion}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class PromoteTemplateVersionParams extends QueryParams<PromoteTemplateVersionParams> {
  /** Creates an empty parameter set. */
  public PromoteTemplateVersionParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public PromoteTemplateVersionParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected PromoteTemplateVersionParams self() {
    return this;
  }
}
