package app.suiss.relay.params;

/** Query parameters of {@code getMailboxRecord}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetMailboxRecordParams extends QueryParams<GetMailboxRecordParams> {
  /** Creates an empty parameter set. */
  public GetMailboxRecordParams() {}

  /**
   * Sets {@code content}.
   *
   * @param value the value
   * @return these parameters
   */
  public GetMailboxRecordParams content(String value) {
    return set("content", value);
  }

  @Override
  protected GetMailboxRecordParams self() {
    return this;
  }
}
