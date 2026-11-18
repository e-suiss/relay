package app.suiss.relay.params;

/** Query parameters of {@code listMailboxDeadLetters}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class ListMailboxDeadLettersParams extends QueryParams<ListMailboxDeadLettersParams> {
  /** Creates an empty parameter set. */
  public ListMailboxDeadLettersParams() {}

  /**
   * Sets {@code limit}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListMailboxDeadLettersParams limit(long value) {
    return set("limit", Long.toString(value));
  }

  /**
   * Sets {@code starting_after}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListMailboxDeadLettersParams startingAfter(String value) {
    return set("starting_after", value);
  }

  /**
   * Sets {@code ending_before}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListMailboxDeadLettersParams endingBefore(String value) {
    return set("ending_before", value);
  }

  /**
   * Sets {@code mailbox_id}.
   *
   * @param value the value
   * @return these parameters
   */
  public ListMailboxDeadLettersParams mailboxId(String value) {
    return set("mailbox_id", value);
  }

  @Override
  protected ListMailboxDeadLettersParams self() {
    return this;
  }
}
