package app.suiss.relay.params;

/** Query parameters of {@code getMailboxEnvelope}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetMailboxEnvelopeParams extends QueryParams<GetMailboxEnvelopeParams> {
  /** Creates an empty parameter set. */
  public GetMailboxEnvelopeParams() {}

  /**
   * Sets {@code record_id} (required).
   *
   * @param value the value
   * @return these parameters
   */
  public GetMailboxEnvelopeParams recordId(String value) {
    return set("record_id", value);
  }

  @Override
  protected GetMailboxEnvelopeParams self() {
    return this;
  }
}
