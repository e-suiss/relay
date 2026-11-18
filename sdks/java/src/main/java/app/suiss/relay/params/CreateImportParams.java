package app.suiss.relay.params;

/** Query parameters of {@code createImport}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class CreateImportParams extends QueryParams<CreateImportParams> {
  /** Creates an empty parameter set. */
  public CreateImportParams() {}

  /**
   * Sets {@code type} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public CreateImportParams type(String value) {
    return set("type", value);
  }

  /**
   * Sets {@code batch} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public CreateImportParams batch(String value) {
    return set("batch", value);
  }

  @Override
  protected CreateImportParams self() {
    return this;
  }
}
