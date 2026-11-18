package app.suiss.relay.params;

/** Query parameters of {@code replacePartialDraft}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ReplacePartialDraftParams extends QueryParams<ReplacePartialDraftParams> {
  /** Creates an empty parameter set. */
  public ReplacePartialDraftParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public ReplacePartialDraftParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected ReplacePartialDraftParams self() {
    return this;
  }
}
