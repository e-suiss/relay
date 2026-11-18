package app.suiss.relay.params;

/** Query parameters of {@code createPartial}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class CreatePartialParams extends QueryParams<CreatePartialParams> {
  /** Creates an empty parameter set. */
  public CreatePartialParams() {}

  /**
   * Sets {@code subtenant}.
   *
   * @param value the value
   * @return these parameters
   */
  public CreatePartialParams subtenant(String value) {
    return set("subtenant", value);
  }

  @Override
  protected CreatePartialParams self() {
    return this;
  }
}
