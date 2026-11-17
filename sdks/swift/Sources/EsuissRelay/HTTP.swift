import EsuissRelayAPI
import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// RFC 3339 timestamps with or without fractional seconds.
struct RelayDateTranscoder: DateTranscoder {
  func encode(_ date: Date) throws -> String {
    Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
  }

  func decode(_ string: String) throws -> Date {
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
      return date
    }
    return try Date.ISO8601FormatStyle().parse(string)
  }
}

/// Adds the subscriber token, the pinned API version, and turns problem responses into `RelayError`.
struct RelayMiddleware: ClientMiddleware {
  let tokens: TokenStore

  func intercept(
    _ request: HTTPRequest,
    body: HTTPBody?,
    baseURL: URL,
    operationID: String,
    next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
  ) async throws -> (HTTPResponse, HTTPBody?) {
    var request = request
    let token = try await tokens.token()
    request.headerFields[.authorization] = "Bearer \(token.value)"
    request.headerFields[HTTPField.Name("Relay-Version")!] = RelayConfiguration.apiVersion
    let (response, responseBody) = try await next(request, body, baseURL)
    guard response.status.code >= 400 else { return (response, responseBody) }
    throw await RelayMiddleware.problem(response: response, body: responseBody)
  }

  static func problem(response: HTTPResponse, body: HTTPBody?) async -> RelayError {
    let retryAfter = response.headerFields[HTTPField.Name("Retry-After")!].flatMap {
      TimeInterval($0.trimmingCharacters(in: .whitespaces))
    }
    var data = Data()
    if let body {
      data = (try? await Data(collecting: body, upTo: 1 << 20)) ?? Data()
    }
    if let problem = try? JSONDecoder().decode(RelayProblem.self, from: data) {
      return .problem(problem, retryAfter: retryAfter)
    }
    return .unexpectedStatus(response.status.code)
  }
}

/// Calls the generated client with the retry rules of the SDK: only retryable errors are repeated,
/// with full jitter backoff and `Retry-After` as a floor, and a mutation keeps its idempotency key.
final class RelayHTTP: Sendable {
  let client: Client
  let tokens: TokenStore
  let configuration: RelayConfiguration
  let backoff = FullJitterBackoff(base: 0.5, cap: 30)

  init(configuration: RelayConfiguration, transport: (any ClientTransport)? = nil) {
    self.configuration = configuration
    let tokens = TokenStore(provider: configuration.tokenProvider, clock: configuration.clock)
    self.tokens = tokens
    self.client = Client(
      serverURL: configuration.baseURL,
      configuration: Configuration(dateTranscoder: RelayDateTranscoder()),
      transport: transport ?? URLSessionTransport(),
      middlewares: [RelayMiddleware(tokens: tokens)]
    )
  }

  // X-29
  func perform<T: Sendable>(
    scope: RelayScope,
    _ operation: @Sendable (Client) async throws -> T
  ) async throws -> T {
    let token = try await tokens.token()
    guard token.allows(scope) else { throw RelayError.missingScope(scope) }
    var attempt = 0
    var refreshed = false
    while true {
      do {
        return try await operation(client)
      } catch {
        if Task.isCancelled { throw CancellationError() }
        let relayError = RelayHTTP.unwrap(error)
        if case .problem(let problem, _) = relayError, problem.status == 401, !refreshed,
          problem.code == "auth_expired_token" || problem.code == "auth_invalid_token"
        {
          refreshed = true
          _ = try await tokens.refresh()
          continue
        }
        guard relayError.isRetryable, attempt < configuration.maxRetries else { throw relayError }
        let delay = backoff.delay(
          attempt: attempt,
          random: configuration.random,
          retryAfter: relayError.retryAfter
        )
        attempt += 1
        configuration.logger.log(.debug, "retrying after a retryable error")
        try await configuration.clock.sleep(seconds: delay)
      }
    }
  }

  static func unwrap(_ error: any Error) -> RelayError {
    if let relayError = error as? RelayError { return relayError }
    if let clientError = error as? ClientError { return unwrap(clientError.underlyingError) }
    if error is CancellationError { return .transport("cancelled") }
    if let urlError = error as? URLError {
      return .transport("network error \(urlError.code.rawValue)")
    }
    return .invalidResponse(String(describing: type(of: error)))
  }
}
