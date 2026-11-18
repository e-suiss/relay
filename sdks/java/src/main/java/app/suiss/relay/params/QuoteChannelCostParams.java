package app.suiss.relay.params;

/** Query parameters of {@code quoteChannelCost}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class QuoteChannelCostParams extends QueryParams<QuoteChannelCostParams> {
  /** Creates an empty parameter set. */
  public QuoteChannelCostParams() {}

  /**
   * Sets {@code channel} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public QuoteChannelCostParams channel(String value) {
    return set("channel", value);
  }

  /**
   * Sets {@code country} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public QuoteChannelCostParams country(String value) {
    return set("country", value);
  }

  /**
   * Sets {@code category}.
   *
   * @param value the value
   * @return these parameters
   */
  public QuoteChannelCostParams category(String value) {
    return set("category", value);
  }

  /**
   * Sets {@code quantity}.
   *
   * @param value the value
   * @return these parameters
   */
  public QuoteChannelCostParams quantity(long value) {
    return set("quantity", Long.toString(value));
  }

  @Override
  protected QuoteChannelCostParams self() {
    return this;
  }
}
