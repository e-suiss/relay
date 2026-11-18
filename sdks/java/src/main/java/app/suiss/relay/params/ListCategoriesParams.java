package app.suiss.relay.params;

/** Query parameters of {@code listCategories}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListCategoriesParams extends QueryParams<ListCategoriesParams> {
  /** Creates an empty parameter set. */
  public ListCategoriesParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListCategoriesParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListCategoriesParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListCategoriesParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListCategoriesParams self() {
    return this;
  }
}
