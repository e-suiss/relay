package app.suiss.relay.params;

/** Query parameters of {@code replaceLayoutDraft}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ReplaceLayoutDraftParams extends QueryParams<ReplaceLayoutDraftParams> {
  /** Creates an empty parameter set. */
  public ReplaceLayoutDraftParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public ReplaceLayoutDraftParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected ReplaceLayoutDraftParams self() {
    return this;
  }
}
