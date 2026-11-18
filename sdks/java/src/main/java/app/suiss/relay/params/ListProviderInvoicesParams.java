package app.suiss.relay.params;

/** Query parameters of {@code listProviderInvoices}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListProviderInvoicesParams extends QueryParams<ListProviderInvoicesParams> {
  /** Creates an empty parameter set. */
  public ListProviderInvoicesParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListProviderInvoicesParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListProviderInvoicesParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListProviderInvoicesParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListProviderInvoicesParams self() {
    return this;
  }
}
