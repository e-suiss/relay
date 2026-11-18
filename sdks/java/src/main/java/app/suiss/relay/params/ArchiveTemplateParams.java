package app.suiss.relay.params;

/** Query parameters of {@code archiveTemplate}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ArchiveTemplateParams extends QueryParams<ArchiveTemplateParams> {
  /** Creates an empty parameter set. */
  public ArchiveTemplateParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public ArchiveTemplateParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected ArchiveTemplateParams self() {
    return this;
  }
}
