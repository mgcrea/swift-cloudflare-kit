import Foundation
import Network
import os

/// A one-shot loopback HTTP listener that catches the OAuth redirect.
///
/// Cloudflare's self-serve OAuth clients may only use the `authorization_code` grant — the
/// device-code grant appears in the discovery document but is not offered to them — so
/// there has to be a redirect, and a desktop app's only option is loopback. This is why a
/// consuming app target must set `ENABLE_INCOMING_NETWORK_CONNECTIONS = YES`; under the App
/// Sandbox the bind fails with no useful error without it, and the symptom is a sign-in
/// that hangs until it times out.
///
/// `ASWebAuthenticationSession` cannot be used for this. Its `callbackURLScheme` cannot be
/// `http`, so it cannot intercept a loopback redirect, and Cloudflare does not accept a
/// custom scheme as a `redirect_uri`. Sending the user to their real browser is also the
/// better outcome: they are usually already signed in to Cloudflare there.
///
/// On iOS, opening the browser backgrounds the app, so a caller must hold a background task
/// assertion for the duration — a suspended app's listener does not accept connections.
///
/// `@unchecked Sendable`: every mutable field is touched only on `queue`, which is serial.
public final class LoopbackRedirectListener: @unchecked Sendable {

  private let configuration: CloudflareOAuthConfiguration
  private let queue: DispatchQueue
  private let log: Logger

  private var listener: NWListener?
  private var continuation: CheckedContinuation<String, Error>?
  private var expectedState = ""
  private var finished = false
  /// The outcome, held for a `waitForCode` that has not been reached yet.
  private var settled: Result<String, Error>?

  /// The port that was actually bound. Callers need it before opening the browser, because
  /// it is part of the `redirect_uri` the authorization request must carry.
  public private(set) var boundPort: UInt16 = 0

  public init(configuration: CloudflareOAuthConfiguration) {
    self.configuration = configuration
    self.queue = DispatchQueue(label: "\(configuration.loggingSubsystem).oauth-loopback")
    self.log = Logger(subsystem: configuration.loggingSubsystem, category: "oauth-loopback")
  }

  /// The default wait for the browser to come back.
  ///
  /// Shorter on iOS: there, a backgrounded app's socket stops accepting once the assertion
  /// expires, so a longer wait would only postpone a failure the user cannot influence.
  #if os(iOS)
    public static let defaultTimeout: TimeInterval = 120
  #else
    public static let defaultTimeout: TimeInterval = 300
  #endif

  /// Binds the first port in the configuration that is free.
  ///
  /// Any loopback port would in fact be accepted — Cloudflare applies RFC 8252 §7.3, so the
  /// port is not matched against the registration (the path is). The fixed list exists to
  /// stay clear of sibling apps' ports rather than because Cloudflare demands it, which is
  /// also why falling back to an ephemeral port would be a safe change if it ever helps.
  ///
  /// - Parameter expectedState: taken here rather than in ``waitForCode(timeout:)`` because
  ///   the caller opens the browser as soon as this returns. A fast redirect can land
  ///   before `waitForCode` is reached, and a listener that had not yet been told what to
  ///   expect would reject the real response as a state mismatch.
  @discardableResult
  public func start(expectedState: String, ports: [UInt16]? = nil) throws -> UInt16 {
    queue.sync { self.expectedState = expectedState }
    for candidate in ports ?? configuration.redirectPorts {
      guard let port = NWEndpoint.Port(rawValue: candidate) else { continue }
      let parameters = NWParameters.tcp
      // Refuse anything arriving from off-machine. The redirect only ever comes from a
      // browser on this device, so binding wider would be surface for no benefit.
      parameters.requiredInterfaceType = .loopback
      parameters.allowLocalEndpointReuse = true
      do {
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in
          self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        self.boundPort = candidate
        log.info("OAuth loopback listening on 127.0.0.1:\(candidate)")
        return candidate
      } catch {
        log.info("Port \(candidate) unavailable: \(error.localizedDescription)")
        continue
      }
    }
    throw CloudflareOAuthError.noAvailablePort
  }

  /// Waits for the browser to arrive, and returns the authorization code.
  ///
  /// The timeout exists because the user may simply never finish — close the tab, walk away
  /// — and a listener left bound would hold the port against the next attempt.
  public func waitForCode(timeout: TimeInterval = defaultTimeout) async throws -> String {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async { [weak self] in
          guard let self else {
            continuation.resume(throwing: CloudflareOAuthError.cancelled)
            return
          }
          // The browser can beat us here. `finish` already ran, so resume from the stored
          // result rather than waiting for a callback that is gone.
          if let settled = self.settled {
            continuation.resume(with: settled)
            return
          }
          self.continuation = continuation
          // Weak, so a listener whose sign-in completed is not held alive for the rest of
          // the timeout window.
          self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(CloudflareOAuthError.timedOut))
          }
        }
      }
    } onCancel: {
      queue.async { [weak self] in self?.finish(.failure(CloudflareOAuthError.cancelled)) }
    }
  }

  public func stop() {
    queue.async { self.finish(.failure(CloudflareOAuthError.cancelled)) }
  }

  // MARK: - Private

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    // 8 KB is far more than a redirect request line; anything larger is not our browser.
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      [weak self] data, _, _, _ in
      guard let self else { return }
      let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      let requestLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""

      let result: Result<String, Error>
      if let query = LoopbackRedirectParser.queryItems(requestLine: requestLine) {
        result = LoopbackRedirectParser.outcome(query: query, expectedState: self.expectedState)
          .mapError { $0 as Error }
      } else {
        // Not a redirect — a probe, a favicon request, anything. Answer it and keep waiting
        // rather than failing the sign-in on unrelated traffic.
        connection.send(
          content: LoopbackRedirectParser.httpResponse(
            success: false, appName: self.configuration.appName),
          completion: .contentProcessed { _ in connection.cancel() })
        return
      }

      let succeeded = (try? result.get()) != nil
      connection.send(
        content: LoopbackRedirectParser.httpResponse(
          success: succeeded, appName: self.configuration.appName),
        completion: .contentProcessed { _ in
          connection.cancel()
          // Resume only after the page is on the wire, so the user is not left looking at a
          // failed connection while the app has already moved on.
          self.finish(result)
        }
      )
    }
  }

  private func finish(_ result: Result<String, Error>) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !finished else { return }
    finished = true
    settled = result
    listener?.cancel()
    listener = nil
    continuation?.resume(with: result)
    continuation = nil
  }
}
