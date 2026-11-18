package app.suiss.relay.params;

/** Query parameters of {@code listWhatsappTemplates}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListWhatsappTemplatesParams extends QueryParams<ListWhatsappTemplatesParams> {
  /** Creates an empty parameter set. */
  public ListWhatsappTemplatesParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWhatsappTemplatesParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWhatsappTemplatesParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWhatsappTemplatesParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListWhatsappTemplatesParams self() {
    return this;
  }
}
