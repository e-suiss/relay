package app.suiss.relay.params;

/** Query parameters of {@code archivePartial}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ArchivePartialParams extends QueryParams<ArchivePartialParams> {
  /** Creates an empty parameter set. */
  public ArchivePartialParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public ArchivePartialParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected ArchivePartialParams self() {
    return this;
  }
}
