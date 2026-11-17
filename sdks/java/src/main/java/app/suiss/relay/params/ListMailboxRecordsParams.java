package app.suiss.relay.params;

/** Query parameters of {@code listMailboxRecords}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListMailboxRecordsParams extends QueryParams<ListMailboxRecordsParams> {
  /** Creates an empty parameter set. */
  public ListMailboxRecordsParams() {}

  /**
   * Sets {@code since}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListMailboxRecordsParams since(String value) {
    return set("since", value);
  }

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListMailboxRecordsParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  @Override
  protected ListMailboxRecordsParams self() {
    return this;
  }
}
