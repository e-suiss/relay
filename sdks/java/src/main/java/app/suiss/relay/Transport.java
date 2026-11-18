package app.suiss.relay;

import java.io.IOException;
import java.net.URI;
import java.time.Duration;
import java.util.List;
import java.util.Map;

/** Sends one HTTP request. Replace it to route requests through your own HTTP stack. */
public interface Transport {
  /**
   * Sends a request and returns the response, whatever its status.
   *
   * @param request the request
   * @return the response
   * @throws IOException when no response arrives
   */
  Response send(Request request) throws IOException;

  /**
   * An HTTP request.
   *
   * @param method the HTTP method
   * @param uri the absolute URI
   * @param headers the headers
   * @param body the body, or null
   * @param timeout the time allowed for the response
   */
  record Request(
      String method, URI uri, Map<String, List<String>> headers, byte[] body, Duration timeout) {

    /**
     * The first value of a header, matched without regard to case.
     *
     * @param name the header name
     * @return the value, or null
     */
    public String header(String name) {
      return Headers.first(headers, name);
    }
  }

  /**
   * An HTTP response.
   *
   * @param status the status code
   * @param headers the headers
   * @param body the body bytes
   */
  record Response(int status, Map<String, List<String>> headers, byte[] body) {

    /**
     * The first value of a header, matched without regard to case.
     *
     * @param name the header name
     * @return the value, or null
     */
    public String header(String name) {
      return Headers.first(headers, name);
    }
  }
}
