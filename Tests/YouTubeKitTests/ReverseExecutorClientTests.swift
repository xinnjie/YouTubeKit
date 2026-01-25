#if canImport(YTDLPAPI)
  import Foundation
  import GRPCCore
  import Testing
  import YTDLPAPI
  @testable import YouTubeKit

  private enum TestData {
    static func string(named name: String, file: StaticString = #filePath) -> String {
      let directory = URL(fileURLWithPath: String(describing: file))
        .deletingLastPathComponent()
        .appendingPathComponent("testdata")
      let fileURL = directory.appendingPathComponent(name)

      do {
        return try String(contentsOf: fileURL, encoding: .utf8)
      } catch {
        fatalError("Failed to load test data \(name): \(error)")
      }
    }
  }

  struct ReverseExecutorClientTests {
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    actor MessageRecorder {
      private var messages: [Ytdlp_V1_ClientMessage] = []
      private var taskID: String?
      private var taskIDContinuation: CheckedContinuation<String, Never>?

      func append(_ message: Ytdlp_V1_ClientMessage) {
        messages.append(message)
        if case .taskRequest(let request) = message.payload {
          if let continuation = taskIDContinuation {
            taskIDContinuation = nil
            continuation.resume(returning: request.taskID)
          } else {
            taskID = request.taskID
          }
        }
      }

      func waitForTaskID() async -> String {
        if let taskID {
          return taskID
        }

        return await withCheckedContinuation { continuation in
          taskIDContinuation = continuation
        }
      }

      func allMessages() -> [Ytdlp_V1_ClientMessage] {
        messages
      }
    }

    @Test("extract parses provided audio and video fixtures")
    func extractParsesProvidedFixtures() async throws {
      guard #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) else {
        return
      }

      let recorder = MessageRecorder()
      let infoJson = TestData.string(named: "ytdlp-sample.json")
      let mock = MockReverseExecutorClient(
        recorder: recorder,
        responseBuilder: { taskID in
          let result = Ytdlp_V1_ExtractResult.with {
            $0.taskID = taskID
            $0.infoJson = infoJson
          }
          return Ytdlp_V1_ServerMessage.with {
            $0.extractResult = result
          }
        })

      let client = ReverseExecutorClient(client: mock)
      let streams = try await client.extract(videoID: "fixture")
      #expect(streams.count >= 2)

      let expectedAudioStream = try #require(
        streams.first { stream in
          stream.audioCodec != nil && stream.videoCodec == nil && stream.itag.itag == 139
        })
      #expect(expectedAudioStream.fileExtension == .m4a)
      if case .mp4a(let version)? = expectedAudioStream.audioCodec {
        #expect(version == "40.5")
      } else {
        #expect(Bool(false))
      }
      #expect(expectedAudioStream.videoCodec == nil)
      #expect(expectedAudioStream.averageBitrate == 48_795)
      #expect(expectedAudioStream.bitrate == 48_795)

      let expectedVideoStream = try #require(
        streams.first { stream in
          stream.videoCodec != nil && stream.audioCodec == nil
        })
      #expect(expectedVideoStream.fileExtension == .mp4)
      #expect(expectedVideoStream.videoCodec != nil)
      #expect(expectedVideoStream.audioCodec == nil)
      #expect((expectedVideoStream.averageBitrate ?? 0) > 0)
      #expect((expectedVideoStream.bitrate ?? 0) > 0)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    struct NoResponseClient: Ytdlp_V1_ReverseExecutor.ClientProtocol {
      let recorder: MessageRecorder

      func taskStream<Result>(
        request: StreamingClientRequest<Ytdlp_V1_ClientMessage>,
        serializer: some MessageSerializer<Ytdlp_V1_ClientMessage>,
        deserializer: some MessageDeserializer<Ytdlp_V1_ServerMessage>,
        options: CallOptions,
        onResponse handleResponse:
          @Sendable @escaping (StreamingClientResponse<Ytdlp_V1_ServerMessage>) async throws ->
          Result
      ) async throws -> Result where Result: Sendable {
        let writer = RPCWriter(wrapping: CapturingWriter(recorder: recorder))
        let producerTask = Task {
          try await request.producer(writer)
        }
        defer {
          producerTask.cancel()
        }

        let bodyParts = AsyncThrowingStream<
          StreamingClientResponse<Ytdlp_V1_ServerMessage>.Contents.BodyPart,
          Error
        > { continuation in
          continuation.finish()
        }

        let response = StreamingClientResponse(
          of: Ytdlp_V1_ServerMessage.self,
          metadata: Metadata(),
          bodyParts: RPCAsyncSequence(wrapping: bodyParts)
        )
        return try await handleResponse(response)
      }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    struct ErroringReverseExecutorClient: Ytdlp_V1_ReverseExecutor.ClientProtocol {
      let error: RPCError

      func taskStream<Result>(
        request: StreamingClientRequest<Ytdlp_V1_ClientMessage>,
        serializer: some MessageSerializer<Ytdlp_V1_ClientMessage>,
        deserializer: some MessageDeserializer<Ytdlp_V1_ServerMessage>,
        options: CallOptions,
        onResponse handleResponse:
          @Sendable @escaping (StreamingClientResponse<Ytdlp_V1_ServerMessage>) async throws ->
          Result
      ) async throws -> Result where Result: Sendable {
        throw error
      }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    struct CapturingWriter: RPCWriterProtocol {
      let recorder: MessageRecorder

      func write(_ element: Ytdlp_V1_ClientMessage) async throws {
        await recorder.append(element)
      }

      func write(contentsOf elements: some Sequence<Ytdlp_V1_ClientMessage>) async throws {
        for element in elements {
          await recorder.append(element)
        }
      }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    struct MockReverseExecutorClient: Ytdlp_V1_ReverseExecutor.ClientProtocol {
      let recorder: MessageRecorder
      let responseBuilder: @Sendable (String) -> Ytdlp_V1_ServerMessage

      func taskStream<Result>(
        request: StreamingClientRequest<Ytdlp_V1_ClientMessage>,
        serializer: some MessageSerializer<Ytdlp_V1_ClientMessage>,
        deserializer: some MessageDeserializer<Ytdlp_V1_ServerMessage>,
        options: CallOptions,
        onResponse handleResponse:
          @Sendable @escaping (StreamingClientResponse<Ytdlp_V1_ServerMessage>) async throws ->
          Result
      ) async throws -> Result where Result: Sendable {
        let writer = RPCWriter(wrapping: CapturingWriter(recorder: recorder))
        let producerTask = Task {
          try await request.producer(writer)
        }
        defer {
          producerTask.cancel()
        }

        let bodyParts = AsyncThrowingStream<
          StreamingClientResponse<Ytdlp_V1_ServerMessage>.Contents.BodyPart,
          Error
        > { continuation in
          Task {
            let taskID = await recorder.waitForTaskID()
            let serverMessage = responseBuilder(taskID)
            continuation.yield(.message(serverMessage))
            continuation.yield(.trailingMetadata(Metadata()))
            continuation.finish()
          }
        }

        let response = StreamingClientResponse(
          of: Ytdlp_V1_ServerMessage.self,
          metadata: Metadata(),
          bodyParts: RPCAsyncSequence(wrapping: bodyParts)
        )
        return try await handleResponse(response)
      }
    }

    @Test("extract returns parsed remote streams")
    func extractReturnsRemoteStreams() async throws {
      guard #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) else {
        return
      }
      let recorder = MessageRecorder()
      let infoJson = """
        {
            "id": "video",
            "title": "Sample",
            "formats": [
                {
                    "format_id": "18",
                    "url": "https://example.com/stream.mp4",
                    "ext": "mp4",
                    "vcodec": "avc1",
                    "acodec": "mp4a.40.2",
                    "tbr": 100.0,
                    "abr": 64.0,
                    "vbr": 36.0,
                    "filesize": 1234
                }
            ]
        }
        """
      let mock = MockReverseExecutorClient(
        recorder: recorder,
        responseBuilder: { taskID in
          let result = Ytdlp_V1_ExtractResult.with {
            $0.taskID = taskID
            $0.infoJson = infoJson
          }
          return Ytdlp_V1_ServerMessage.with {
            $0.extractResult = result
          }
        })
      let client = ReverseExecutorClient(
        client: mock,
        deviceID: "device-id",
        userAgent: "unit-test"
      )

      let streams = try await client.extract(videoID: "abc123")
      #expect(streams.count == 1)
      let stream = try #require(streams.first)
      #expect(stream.url == URL(string: "https://example.com/stream.mp4"))
      #expect(stream.itag.itag == 18)
      #expect(stream.fileExtension == .mp4)
      if case .avc1(let version)? = stream.videoCodec {
        #expect(version.isEmpty)
      } else {
        #expect(Bool(false))
      }
      if case .mp4a(let version)? = stream.audioCodec {
        #expect(version == "40.2")
      } else {
        #expect(Bool(false))
      }
      #expect(stream.averageBitrate == 100_000)
      #expect(stream.bitrate == 36_000)

      let messages = await recorder.allMessages()
      #expect(messages.count >= 2)
      if case .hello(let hello) = messages.first?.payload {
        #expect(hello.deviceID == "device-id")
      } else {
        #expect(Bool(false))
      }
      if case .taskRequest(let request) = messages.dropFirst().first?.payload {
        #expect(request.url == "https://www.youtube.com/watch?v=abc123")
        #expect(request.options["quiet"] == "true")
      } else {
        #expect(Bool(false))
      }
    }

    @Test("extract throws remote error")
    func extractThrowsRemoteError() async {
      guard #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) else {
        return
      }
      let error = RPCError(code: .internalError, message: "boom")
      let client = ReverseExecutorClient(client: ErroringReverseExecutorClient(error: error))

      do {
        _ = try await client.extract(videoID: "abc123")
        #expect(Bool(false))
      } catch {
        if case .remoteError(let message) = error as? YouTubeKitError {
          #expect(message == "boom")
        } else {
          #expect(Bool(false))
        }
      }
    }

    @Test("extract times out when no response arrives")
    func extractTimesOut() async {
      guard #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) else {
        return
      }
      let recorder = MessageRecorder()
      let mock = NoResponseClient(recorder: recorder)
      let client = ReverseExecutorClient(client: mock)

      do {
        _ = try await client.extract(videoID: "abc123", timeout: 0.1)
        #expect(Bool(false))
      } catch {
        if case .extractTimeout = error as? YouTubeKitError {
          #expect(Bool(true))
        } else {
          #expect(Bool(false))
        }
      }
    }
  }
#endif
