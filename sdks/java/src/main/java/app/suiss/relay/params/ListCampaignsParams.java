package app.suiss.relay.params;

/** Query parameters of {@code listCampaigns}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListCampaignsParams extends QueryParams<ListCampaignsParams> {
  /** Creates an empty parameter set. */
  public ListCampaignsParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListCampaignsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListCampaignsParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListCampaignsParams endingBefore(String value) {
    return set("ending_before", value);
  }

  @Override
  protected ListCampaignsParams self() {
    return this;
  }
}
