package app.suiss.relay;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.List;
import java.util.Map;
import java.util.Random;

final class Stub implements Transport {
  static final Instant NOW = Instant.parse("2026-11-18T09:00:00Z");

  interface Answer {
    Response answer(Request request) throws IOException;
  }

  final List<Request> requests = new ArrayList<>();
  final List<Duration> sleeps = new ArrayList<>();
  private final Deque<Answer> answers = new ArrayDeque<>();

  Stub reply(int status, String body, String... headers) {
    answers.add(request -> response(status, body, headers));
    return this;
  }

  Stub fail(String message) {
    answers.add(
        request -> {
          throw new IOException(message);
        });
    return this;
  }

  Stub answer(Answer answer) {
    answers.add(answer);
    return this;
  }

  static Response response(int status, String body, String... headers) {
    Map<String, List<String>> map = new java.util.LinkedHashMap<>();
    for (int i = 0; i + 1 < headers.length; i += 2) {
      map.put(headers[i], List.of(headers[i + 1]));
    }
    return new Response(status, map, body.getBytes(StandardCharsets.UTF_8));
  }

  @Override
  public Response send(Request request) throws IOException {
    requests.add(request);
    Answer answer = answers.poll();
    if (answer == null) {
      throw new AssertionError("unexpected request " + request.method() + " " + request.uri());
    }
    return answer.answer(request);
  }

  RelayClient client() {
    return client(3);
  }

  RelayClient client(int maxRetries) {
    return RelayClient.builder()
        .baseUrl("https://relay.example.com")
        .credentials(DpopCredentials.of(DpopKey.generate(), "token-1"))
        .transport(this)
        .maxRetries(maxRetries)
        .sleeper(sleeps::add)
        .clock(Clock.fixed(NOW, ZoneOffset.UTC))
        .random(new FixedRandom(0.5))
        .build();
  }

  static final class FixedRandom extends Random {
    private static final long serialVersionUID = 1L;

    private final double value;

    FixedRandom(double value) {
      super(7);
      this.value = value;
    }

    @Override
    public double nextDouble() {
      return value;
    }
  }
}
