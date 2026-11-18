package app.suiss.relay.params;

/** Query parameters of {@code listProviderAccounts}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListProviderAccountsParams extends QueryParams<ListProviderAccountsParams> {
  /** Creates an empty parameter set. */
  public ListProviderAccountsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListProviderAccountsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListProviderAccountsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListProviderAccountsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListProviderAccountsParams self() {
    return this;
  }
}
