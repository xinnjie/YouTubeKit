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
    private let outboundStream: AsyncStream<Ytdlp_V1_ClientMessage>
    private let outboundContinuation: AsyncStream<Ytdlp_V1_ClientMessage>.Continuation
    private let continuationStore = ContinuationStore()

    public let id: UUID

    public init(
      client: Client,
      deviceID: String = UUID().uuidString,
      userAgent: String =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    ) {
      self.id = UUID()
      self.deviceID = deviceID
      self.userAgent = userAgent
      self.client = client

      let stream = AsyncStream<Ytdlp_V1_ClientMessage>.makeStream()
      self.outboundStream = stream.stream
      self.outboundContinuation = stream.continuation
    }

    public init<Transport: ClientTransport>(
      grpcClient: GRPCClient<Transport>,
      deviceID: String = UUID().uuidString,
      userAgent: String =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    ) where Client == Ytdlp_V1_ReverseExecutor.Client<Transport> {
      self.init(
        client: Ytdlp_V1_ReverseExecutor.Client(wrapping: grpcClient),
        deviceID: deviceID,
        userAgent: userAgent
      )
    }

    /// Connects to the server, requests streams for the video, processes requests, and returns the result.
    /// This is an ephemeral operation: it connects, does the work, and disconnects.
    public func extract(videoID: String, timeout: TimeInterval = 15) async throws -> [RemoteStream]
    {
      let loopTask = Task {
        try await self.startLoop()
      }
      defer {
        outboundContinuation.finish()
        loopTask.cancel()
      }

      let taskID = UUID().uuidString
      let timeoutTask = Task {
        guard timeout > 0 else { return }
        let duration = UInt64(timeout * 1_000_000_000)
        do {
          try await Task.sleep(nanoseconds: duration)
        } catch {
          return
        }

        if let continuation = await self.continuationStore.take(for: taskID) {
          continuation.resume(throwing: YouTubeKitError.extractTimeout)
        }
      }
      defer {
        timeoutTask.cancel()
      }

      return try await withCheckedThrowingContinuation { continuation in
        Task {
          await self.continuationStore.insert(continuation, for: taskID)
          
          let hello = Ytdlp_V1_Hello.with {
            $0.deviceID = self.deviceID
            // $0.userAgent = self.userAgent
            // $0.cookies = ... // TODO: Inject cookies if needed
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

    private func startLoop() async throws {
      try await client.taskStream(
        requestProducer: { writer in
          for await message in outboundStream {
            try await writer.write(message)
          }
        },
        onResponse: { response in
          for try await message in response.messages {
            switch message.payload {
            case .request(let req):
              os_log("Received request", log: self.log, type: .debug)
              await self.handleRequest(req)
            case .extractResult(let result):
              await self.notifyResult(result)
              return
            case .taskAccepted(let accepted):
              os_log(
                "Remote executor task accepted, message: %{public}@", log: self.log, type: .debug,
                accepted.message)
            case .error(let error):
              os_log("Server error: %{public}@", log: self.log, type: .error, error.message)
              await self.notifyError(error)
            case .ping(let ping):
              let pong = Ytdlp_V1_Pong.with { $0.nonce = ping.nonce }
              self.sendMessage(Ytdlp_V1_ClientMessage.with { $0.pong = pong })
            case .cancel:
              break
            case .none:
              break
            }
          }
        }
      )
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

        // Construct Response
        let httpResponse = response as? HTTPURLResponse
        let statusCode = Int32(httpResponse?.statusCode ?? 0)

        // Convert headers
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

    private func parseYtDlpJSON(_ json: Data) throws -> [RemoteStream] {
      let decoder = JSONDecoder()
      let info = try decoder.decode(YtDlpInfo.self, from: json)

      return info.formats.compactMap { format in
        guard let url = URL(string: format.url),
          let itag = Int(format.format_id)
        else {
          return nil
        }

        return RemoteStream(
          url: url,
          itag: itag,
          ext: format.ext,
          videoCodec: format.vcodec == "none" ? nil : format.vcodec,
          audioCodec: format.acodec == "none" ? nil : format.acodec,
          averageBitrate: Int(format.tbr ?? 0) * 1000,  // tbr is usuall kbit/s
          audioBitrate: format.abr.map { Int($0 * 1000) },
          videoBitrate: format.vbr.map { Int($0 * 1000) },
          filesize: format.filesize
        )
      }
    }

    // MARK: - Private Helpers

    private func notifyResult(_ result: Ytdlp_V1_ExtractResult) async {
      if let continuation = await continuationStore.take(for: result.taskID) {
        do {
          let streams = try self.parseYtDlpJSON(result.infoJson)
          continuation.resume(returning: streams)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }

    private func notifyError(_ error: Ytdlp_V1_Error) async {
      guard !error.taskID.isEmpty,
        let continuation = await continuationStore.take(for: error.taskID)
      else {
        return
      }

      continuation.resume(throwing: YouTubeKitError.remoteError(error.message))
    }

    private func sendMessage(_ message: Ytdlp_V1_ClientMessage) {
      outboundContinuation.yield(message)
    }
  }

  @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, visionOS 1.0, *)
  private actor ContinuationStore {
    private var storage: [String: CheckedContinuation<[RemoteStream], Error>] = [:]

    func insert(_ continuation: CheckedContinuation<[RemoteStream], Error>, for taskID: String) {
      storage[taskID] = continuation
    }

    func take(for taskID: String) -> CheckedContinuation<[RemoteStream], Error>? {
      storage.removeValue(forKey: taskID)
    }
  }

  // MARK: - Private Models for yt-dlp JSON
  private struct YtDlpInfo: Decodable {
    let id: String
    let title: String
    let formats: [YtDlpFormat]
  }

  private struct YtDlpFormat: Decodable {
    let format_id: String
    let url: String
    let ext: String
    let vcodec: String?
    let acodec: String?
    let abr: Double?
    let vbr: Double?
    let tbr: Double?  // Total bitrate?
    let filesize: Int?
  }

#endif
