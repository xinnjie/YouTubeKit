//
//  ReverseExecutorClient.swift
//  YouTubeKit
//
//  Created by Cascade on 2026.
//

import Foundation
import os.log

#if canImport(YTDLPAPI)
  import YTDLPAPI
  import GRPCCore
  import GRPCProtobuf
  import GRPCNIOTransportHTTP2

  @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
  public struct ReverseExecutorClient<Client: Ytdlp_V1_ReverseExecutor.ClientProtocol> {

    private let log = OSLog(category: "ReverseExecutorClient")
    private let client: Client
    private let deviceID: String
    private let userAgent: String
    private let cookies: [YouTube.Cookie]
    private let outboundStream: AsyncStream<Ytdlp_V1_ClientMessage>
    private let outboundContinuation: AsyncStream<Ytdlp_V1_ClientMessage>.Continuation
    private let continuationStore = ContinuationStore()

    public let id: UUID

    public init(
      client: Client,
      deviceID: String = UUID().uuidString,
      userAgent: String =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      cookies: [YouTube.Cookie] = []
    ) {
      self.id = UUID()
      self.deviceID = deviceID
      self.userAgent = userAgent
      self.cookies = cookies
      self.client = client

      let stream = AsyncStream<Ytdlp_V1_ClientMessage>.makeStream()
      self.outboundStream = stream.stream
      self.outboundContinuation = stream.continuation
    }

    public init<Transport: ClientTransport>(
      grpcClient: GRPCClient<Transport>,
      deviceID: String = UUID().uuidString,
      userAgent: String =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      cookies: [YouTube.Cookie] = []
    ) where Client == Ytdlp_V1_ReverseExecutor.Client<Transport> {
      self.init(
        client: Ytdlp_V1_ReverseExecutor.Client(wrapping: grpcClient),
        deviceID: deviceID,
        userAgent: userAgent,
        cookies: cookies
      )
    }

    /// Connects to the server, requests streams for the video, processes requests, and returns the result.
    /// This is an ephemeral operation: it connects, does the work, and disconnects.
    public func extract(videoID: String, timeout: TimeInterval = 20) async throws -> [Stream]
    {
      let timeoutDuration: Duration? = timeout > 0 ? .seconds(timeout) : nil
      let loopTask = Task {
        await self.startLoop(callTimeout: timeoutDuration, idleTimeout: timeoutDuration)
      }
      defer {
        outboundContinuation.finish()
        loopTask.cancel()
      }

      let taskID = UUID().uuidString

      return try await withCheckedThrowingContinuation { continuation in
        Task {
          await self.continuationStore.insert(continuation, for: taskID)

          let hello = Ytdlp_V1_Hello.with {
            $0.deviceID = self.deviceID
            $0.userAgent = self.userAgent
            $0.cookies = self.cookies.map { $0.toProto() }
            $0.capabilities = ["http_chunking": "true"]
          }
          self.sendMessage(Ytdlp_V1_ClientMessage.with { $0.hello = hello })

          let taskReq = Ytdlp_V1_TaskRequest.with {
            $0.taskID = taskID
            $0.url = "https://www.youtube.com/watch?v=\(videoID)"
            $0.options = ["quiet": "true", "no_warnings": "true", "skip_download": "true"]
          }
          self.sendMessage(Ytdlp_V1_ClientMessage.with { $0.taskRequest = taskReq })
        }
      }
    }

    private func startLoop(callTimeout: Duration?, idleTimeout: Duration?) async {
      var options = CallOptions.defaults
      options.timeout = callTimeout

      let idleTimer = idleTimeout.flatMap { duration -> IdleTimeoutController? in
        guard duration > .zero else { return nil }
        return IdleTimeoutController(duration: duration) { [self] in
          os_log(
            "Remote executor idle timeout after %{public}@ seconds",
            log: self.log,
            type: .error,
            String(describing: duration))
          await self.handleStreamError(YouTubeKitError.extractTimeout)
          self.outboundContinuation.finish()
        }
      }

      if let idleTimer {
        await idleTimer.arm()
      }

      do {
        try await client.taskStream(
          options: options,
          requestProducer: { writer in
            for await message in outboundStream {
              try await writer.write(message)
            }
          },
          onResponse: { response in
            for try await message in response.messages {
              await idleTimer?.reset()
              switch message.payload {
              case .request(let req):
                os_log(
                  "Proxying remote executor request to video provider", log: self.log, type: .debug)
                await self.handleRequest(req)
              case .extractResult(let result):
                os_log(
                  "Remote executor extraction result received", log: self.log, type: .debug)
                await self.notifyResult(result)
                return
              case .taskAccepted(let accepted):
                os_log(
                  "Remote executor task accepted, message: %{public}@", log: self.log, type: .debug,
                  accepted.message)
              case .none:
                break
              }
            }
          }
        )
      } catch {
        self.logStreamFailure(error)
        await self.handleStreamError(error)
      }

      await idleTimer?.cancel()

      if await continuationStore.hasPendingContinuations() {
        await handleStreamError(YouTubeKitError.extractTimeout)
      }
    }

    // MARK: - HTTP Handling

    private func handleRequest(_ req: Ytdlp_V1_HttpRequest) async {
      guard let url = URL(string: req.url) else { return }

      var urlRequest = URLRequest(url: url)
      urlRequest.httpMethod = req.method

      for (key, value) in req.headers {
        urlRequest.setValue(value, forHTTPHeaderField: key)
      }

      if !req.body.isEmpty {
        urlRequest.httpBody = req.body
      }

      // Timeout
      let timeout = Double(req.timeoutMs) / 1000.0
      let sessionConfig = URLSessionConfiguration.default
      sessionConfig.timeoutIntervalForRequest = timeout > 0 ? timeout : 30
      let session = URLSession(configuration: sessionConfig)

      do {
        let (data, response) = try await session.data(for: urlRequest)

        let httpResponse = response as? HTTPURLResponse
        let statusCode = Int32(httpResponse?.statusCode ?? 0)

        var respHeaders: [String: String] = [:]
        if let httpResponse = httpResponse {
          for (key, value) in httpResponse.allHeaderFields {
            if let keyStr = key as? String, let valStr = value as? String {
              respHeaders[keyStr] = valStr
            }
          }
        }

        let clientResp = Ytdlp_V1_HttpResponse.with {
          $0.requestID = req.requestID
          $0.taskID = req.taskID
          $0.status = statusCode
          $0.headers = respHeaders
          $0.body = data
          $0.finalURL = httpResponse?.url?.absoluteString ?? req.url
        }

        self.sendMessage(Ytdlp_V1_ClientMessage.with { $0.response = clientResp })

      } catch {
        os_log(
          "HTTP request failed: %{public}@", log: self.log, type: .error, error.localizedDescription
        )
        let err = Ytdlp_V1_Error.with {
          $0.requestID = req.requestID
          $0.code = "HTTP_ERROR"
          $0.message = error.localizedDescription
        }
        self.sendMessage(Ytdlp_V1_ClientMessage.with { $0.error = err })
      }
    }

    private func parseYtDlpJSON(_ jsonData: Data) throws -> [Stream] {
      let decoder = JSONDecoder()
      let info = try decoder.decode(YtDlpExtractInfo.self, from: jsonData)

      return info.formats.compactMap { format in
        guard let url = URL(string: format.url),
          let itagValue = Self.itagValue(from: format.formatID),
          // TODO(xinnjie): curently only support https, support HLS in the future
          format.protocolField == "https"
        else {
          return nil
        }

        return try? Stream(
          url: url,
          itagValue: itagValue,
          videoCodecName: Self.nonEmptyCodec(from: format.vcodec),
          audioCodecName: Self.nonEmptyCodec(from: format.acodec),
          fileExtension: format.ext,
          averageBitrate: format.tbr.map { Int($0 * 1000) },
          audioBitrate: format.abr.map { Int($0 * 1000) },
          videoBitrate: format.vbr.map { Int($0 * 1000) },
          filesize: format.filesize,
          formatNote: format.formatNote
        )
      }
    }

    // MARK: - Private Helpers

    private func notifyResult(_ result: Ytdlp_V1_ExtractResult) async {
      if let continuation = await continuationStore.take(for: result.taskID) {
        do {
          guard let data = result.infoJson.data(using: .utf8) else {
            throw YouTubeKitError.remoteError("Invalid yt-dlp payload")
          }
          let streams = try self.parseYtDlpJSON(data)
          continuation.resume(returning: streams)
        } catch {
          #if DEBUG
            if let fileURL = self.persistFailedPayload(result.infoJson) {
              os_log(
                "Saved failing yt-dlp payload to %{public}@",
                log: self.log,
                type: .error,
                fileURL.path)
            }
          #endif
          continuation.resume(throwing: error)
        }
      }
    }

    private func persistFailedPayload(_ payload: String) -> URL? {
      guard let data = payload.data(using: .utf8) else {
        os_log(
          "Failed to encode yt-dlp payload for persistence",
          log: self.log,
          type: .error)
        return nil
      }

      do {
        let cachesURL = try FileManager.default.url(
          for: .cachesDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true)
        let filename = "yt-dlp-error-\(UUID().uuidString).json"
        let fileURL = cachesURL.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
      } catch {
        os_log(
          "Failed to persist yt-dlp payload: %{public}@",
          log: self.log,
          type: .error,
          error.localizedDescription)
        return nil
      }
    }

    private func handleStreamError(_ error: Error) async {
      let continuations = await continuationStore.takeAll()
      guard !continuations.isEmpty else {
        return
      }

      let resolvedError = resolveStreamError(error)
      for continuation in continuations {
        continuation.resume(throwing: resolvedError)
      }
    }

    private func resolveStreamError(_ error: Error) -> Error {
      guard let rpcError = error as? RPCError else {
        return error
      }

      switch rpcError.code {
      case .deadlineExceeded:
        return YouTubeKitError.extractTimeout
      case .unauthenticated:
        return YouTubeKitError.unauthenticated(rpcError.message)
      default:
        let message =
          rpcError.message.isEmpty
          ? "gRPC error \(rpcError.code)"
          : rpcError.message
        return YouTubeKitError.remoteError(message)
      }
    }

    private func logStreamFailure(_ error: Error) {
      if let rpcError = error as? RPCError {
        os_log(
          "Remote executor stream failed (%{public}@): %{public}@",
          log: self.log,
          type: .error,
          String(describing: rpcError.code),
          rpcError.message)
      } else {
        os_log(
          "Remote executor stream failed with error: %{public}@",
          log: self.log,
          type: .error,
          String(describing: error))
      }
    }

    private func sendMessage(_ message: Ytdlp_V1_ClientMessage) {
      outboundContinuation.yield(message)
    }
    private static func nonEmptyCodec(from value: String?) -> String? {
      guard let codec = value, !codec.isEmpty, codec.lowercased() != "none" else {
        return nil
      }
      return codec
    }

    private static func itagValue(from formatID: String) -> Int? {
      if let numericPrefix = formatID.split(separator: "-").first,
        let value = Int(numericPrefix)
      {
        return value
      }
      return Int(formatID)
    }
  }

  @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, visionOS 1.0, *)
  private actor ContinuationStore {
    private var storage: [String: CheckedContinuation<[Stream], Error>] = [:]

    func insert(_ continuation: CheckedContinuation<[Stream], Error>, for taskID: String) {
      storage[taskID] = continuation
    }

    func take(for taskID: String) -> CheckedContinuation<[Stream], Error>? {
      storage.removeValue(forKey: taskID)
    }

    func takeAll() -> [CheckedContinuation<[Stream], Error>] {
      let continuations = Array(storage.values)
      storage.removeAll()
      return continuations
    }

    func hasPendingContinuations() -> Bool {
      !storage.isEmpty
    }
  }

  /// A controller that fires a timeout callback after a period of inactivity.
  ///
  /// Use this actor to detect when a streaming operation has been idle for too long.
  /// Call `arm()` to start the timer and `reset()` each time activity occurs.
  /// If the timer expires without being reset, the `onTimeout` closure is invoked.
  ///
  /// Example usage:
  /// ```swift
  /// let controller = IdleTimeoutController(duration: .seconds(30)) {
  ///     print("Connection timed out due to inactivity")
  /// }
  /// await controller.arm()
  ///
  /// // When activity occurs:
  /// await controller.reset()
  ///
  /// // When done:
  /// await controller.cancel()
  /// ```

  @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
  private actor IdleTimeoutController {
    private let duration: Duration
    private let onTimeout: @Sendable () async -> Void
    private var task: Task<Void, Never>?
    private var hasTimedOut = false

    init(duration: Duration, onTimeout: @escaping @Sendable () async -> Void) {
      self.duration = duration
      self.onTimeout = onTimeout
    }

    func arm() {
      guard !hasTimedOut else { return }
      schedule()
    }

    func reset() {
      guard !hasTimedOut else { return }
      schedule()
    }

    func cancel() {
      task?.cancel()
      task = nil
    }

    private func schedule() {
      task?.cancel()
      let timeout = duration
      task = Task {
        do {
          try await Task.sleep(for: timeout)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        await triggerTimeout()
      }
    }

    private func triggerTimeout() async {
      guard !hasTimedOut else { return }
      hasTimedOut = true
      await onTimeout()
    }
  }

#endif
