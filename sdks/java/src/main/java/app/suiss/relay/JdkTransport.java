package app.suiss.relay;

import java.io.IOException;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.List;
import java.util.Map;

/** The default {@link Transport}, built on {@code java.net.http.HttpClient}. */
public final class JdkTransport implements Transport {
  private final HttpClient client;

  /** Creates a transport with a new HTTP client that never follows redirects. */
  public JdkTransport() {
    this(
        HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .followRedirects(HttpClient.Redirect.NEVER)
            .build());
  }

  /**
   * Creates a transport over an existing HTTP client.
   *
   * @param client the HTTP client
   */
  public JdkTransport(HttpClient client) {
    this.client = client;
  }

  @Override
  public Response send(Request request) throws IOException {
    HttpRequest.BodyPublisher publisher =
        request.body() == null
            ? HttpRequest.BodyPublishers.noBody()
            : HttpRequest.BodyPublishers.ofByteArray(request.body());
    HttpRequest.Builder builder =
        HttpRequest.newBuilder(request.uri())
            .timeout(request.timeout())
            .method(request.method(), publisher);
    for (Map.Entry<String, List<String>> header : request.headers().entrySet()) {
      for (String value : header.getValue()) {
        builder.header(header.getKey(), value);
      }
    }
    try {
      HttpResponse<byte[]> response =
          client.send(builder.build(), HttpResponse.BodyHandlers.ofByteArray());
      return new Response(response.statusCode(), response.headers().map(), response.body());
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new IOException("interrupted while waiting for the response", e);
    }
  }
}
