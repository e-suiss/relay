package app.suiss.relay.params;

/** Query parameters of {@code createLayout}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class CreateLayoutParams extends QueryParams<CreateLayoutParams> {
  /** Creates an empty parameter set. */
  public CreateLayoutParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public CreateLayoutParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected CreateLayoutParams self() {
    return this;
  }
}
