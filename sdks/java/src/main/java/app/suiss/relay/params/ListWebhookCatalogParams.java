package app.suiss.relay.params;

/** Query parameters of {@code listWebhookCatalog}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListWebhookCatalogParams extends QueryParams<ListWebhookCatalogParams> {
  /** Creates an empty parameter set. */
  public ListWebhookCatalogParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookCatalogParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookCatalogParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListWebhookCatalogParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListWebhookCatalogParams self() {
    return this;
  }
}
