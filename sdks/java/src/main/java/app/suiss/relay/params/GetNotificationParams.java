package app.suiss.relay.params;

import java.util.List;

/** Query parameters of {@code getNotification}. */
@javax.annotation.processing.Generated("app.suiss.relay.generator.Generator")
public final class GetNotificationParams extends QueryParams<GetNotificationParams> {
  /** Creates an empty parameter set. */
  public GetNotificationParams() {}

  /**
   * Sets {@code expand}.
   *
   * @param value the value
   * @return these parameters
   */
  public GetNotificationParams expand(List<String> value) {
    return set("expand", String.join(",", value));
  }

  @Override
  protected GetNotificationParams self() {
    return this;
  }
}
