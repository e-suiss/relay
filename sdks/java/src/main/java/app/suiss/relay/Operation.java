package app.suiss.relay;

record Operation(
    String id,
    String method,
    String path,
    Presence idempotency,
    Presence ifMatch,
    Presence body,
    String contentType,
    Response response) {

  enum Presence {
    NONE,
    OPTIONAL,
    REQUIRED
  }

  enum Response {
    JSON,
    TEXT
  }
}
