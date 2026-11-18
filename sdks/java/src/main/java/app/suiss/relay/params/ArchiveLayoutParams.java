package app.suiss.relay.params;

/** Query parameters of {@code archiveLayout}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ArchiveLayoutParams extends QueryParams<ArchiveLayoutParams> {
  /** Creates an empty parameter set. */
  public ArchiveLayoutParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public ArchiveLayoutParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected ArchiveLayoutParams self() {
    return this;
  }
}
