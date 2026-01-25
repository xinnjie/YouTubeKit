import Alamofire
import Foundation

/// An actor responsible for downloading a single YouTube stream.
///
/// `StreamDownloader` handles the complexities of downloading media from YouTube,
/// including overcoming throttling mechanisms and handling network interruptions.
///
/// - Important: **YouTube Throttling and Chunking**
/// YouTube implements server-side throttling to discourage bulk downloading.
/// If a client attempts to download a large file in a single HTTP request,
/// the server may throttle the connection speed significantly after the initial buffering period.
///
/// To bypass this limitation, `StreamDownloader` implements a **chunked download strategy**:
/// 1. The file is split into smaller segments (default 10MB).
/// 2. Each segment is downloaded using a separate HTTP `Range` request.
/// 3. If a segment fails, it can be retried independently without restarting the entire download.
///
/// This approach ensures consistent download speeds and provides robustness against network failures.
@available(macOS 10.15.4, iOS 13.4, watchOS 6.2, tvOS 13.4, *)
public actor StreamDownloader {

  private var session: Session

  public init(session: Session = .default) {
    self.session = session
  }

  /// Current download progress stream.
  /// Note: This stream is shared. If multiple downloads are run sequentially,
  /// consumers needs to be aware. Ideally create a new downloader per task.
  public var progress: AsyncStream<DownloadProgress> {
    _progressStream
  }

  /// Downloads the stream to the specified file URL.
  /// This method blocks until the download is complete or throws an error.
  public func download(
    stream: Stream,
    to outputURL: URL,
    options: DownloadOptions = .default
  ) async throws {
    let totalSize = try await resolveTotalSize(for: stream, options: options)
    try await performChunkedDownload(
      from: stream.url,
      to: outputURL,
      totalSize: totalSize,
      options: options,
      createParentDirectory: false
    )
  }

  /// Downloads content from a URL to the specified file URL.
  ///
  /// This method is designed for use with adapters that don't have access to `Stream` objects.
  /// It uses the same chunked download strategy as the `Stream`-based method.
  ///
  /// - Parameters:
  ///   - url: The URL to download from
  ///   - outputURL: The file URL where the data should be saved
  ///   - options: Configuration options for the download
  /// - Throws: URLError or AFError if the download fails after retries
  public func download(
    url: URL,
    to outputURL: URL,
    options: DownloadOptions = .default
  ) async throws {
    let totalSize = try await resolveTotalSizeFromURL(url: url)
    try await performChunkedDownload(
      from: url,
      to: outputURL,
      totalSize: totalSize,
      options: options,
      createParentDirectory: true
    )
  }

  // MARK: - Shared Download Implementation

  /// Common chunked download implementation used by both public download methods.
  ///
  /// This method handles:
  /// - File state initialization and resume support
  /// - Chunked download loop with progress reporting
  /// - File handle management
  ///
  /// - Parameters:
  ///   - sourceURL: The URL to download from
  ///   - outputURL: The file URL where the data should be saved
  ///   - totalSize: Total size of the content in bytes
  ///   - options: Configuration options for the download
  ///   - createParentDirectory: Whether to create parent directories if they don't exist
  private func performChunkedDownload(
    from sourceURL: URL,
    to outputURL: URL,
    totalSize: Int64,
    options: DownloadOptions,
    createParentDirectory: Bool
  ) async throws {
    // Setup initial file state for resuming
    var currentOffset: Int64 = 0
    if FileManager.default.fileExists(atPath: outputURL.path) {
      let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
      if let fileSize = attributes[.size] as? Int64 {
        currentOffset = fileSize

        // If file is already fully downloaded
        if currentOffset >= totalSize {
          reportProgress(downloaded: totalSize, total: totalSize)
          return
        }
      }
    } else {
      // Create parent directory if needed
      if createParentDirectory {
        let parentDir = outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
      }
      FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: nil)
    }

    let fileHandle = try FileHandle(forWritingTo: outputURL)
    defer { try? fileHandle.close() }

    try fileHandle.seekToEnd()
    reportProgress(downloaded: currentOffset, total: totalSize)

    // Chunk download loop
    while currentOffset < totalSize {
      let remainingBytes = totalSize - currentOffset
      let chunkSize = min(Int64(options.chunkSize), remainingBytes)
      let endOffset = currentOffset + chunkSize - 1
      let range = currentOffset...endOffset

      try await downloadChunk(
        url: sourceURL,
        range: range,
        fileHandle: fileHandle,
        options: options
      )

      currentOffset += chunkSize
      reportProgress(downloaded: currentOffset, total: totalSize)
    }

    progressContinuation?.finish()
  }

  /// Resolves total size from a raw URL (without Stream object).
  private func resolveTotalSizeFromURL(url: URL) async throws -> Int64 {
    // Check URL clen parameter (YouTube specific)
    if let clenStr = url.queryParameters?["clen"], let clen = Int64(clenStr) {
      return clen
    }

    // HEAD request as fallback
    let request = session.request(url, method: .head)
    let response = await request.serializingData().response

    if let contentLength = response.response?.expectedContentLength, contentLength > 0 {
      return contentLength
    }

    throw URLError(.cannotDecodeContentData)
  }

  // MARK: - API

  private var progressContinuation: AsyncStream<DownloadProgress>.Continuation?
  private lazy var _progressStream: AsyncStream<DownloadProgress> = {
    AsyncStream { continuation in
      self.progressContinuation = continuation
    }
  }()

  private func reportProgress(downloaded: Int64, total: Int64) {
    progressContinuation?.yield(DownloadProgress(bytesDownloaded: downloaded, totalBytes: total))
  }

  // MARK: - Internal Logic

  /// Resolves the total size of the stream to download.
  ///
  /// This method uses multiple fallback strategies to determine the file size,
  /// prioritized by reliability:
  ///
  /// **Priority Order:**
  /// 1. **Stream.filesize** (Most Reliable)
  ///    - Comes directly from YouTube API's `contentLength` field
  ///    - This is the authoritative source and should be trusted when available
  ///
  /// 2. **URL `clen` Parameter** (YouTube Specific)
  ///    - YouTube-specific query parameter that indicates content length
  ///    - Fallback when Stream.filesize is not available
  ///    - Still reliable for YouTube streams
  ///
  /// 3. **HEAD Request** (Last Resort)
  ///    - Makes an HTTP HEAD request to get Content-Length header
  ///    - Least reliable as it depends on server response
  ///    - Used only when both previous methods fail
  ///
  /// - Parameters:
  ///   - stream: The stream to resolve size for
  ///   - options: Download options (currently unused but kept for future extensibility)
  /// - Returns: Total size in bytes
  /// - Throws: URLError if all methods fail to determine the size
  private func resolveTotalSize(for stream: Stream, options: DownloadOptions) async throws -> Int64
  {
    // Priority 1: Use Stream.filesize if available (most reliable)
    if let filesize = stream.filesize {
      return Int64(filesize)
    }

    // Priority 2: Check URL clen parameter (YouTube specific)
    if let clenStr = stream.url.queryParameters?["clen"], let clen = Int64(clenStr) {
      return clen
    }

    // Priority 3: HEAD request as last resort
    // Note: YouTube URLs might expire or need signatures. 'stream.url' is assumed valid.
    let request = session.request(stream.url, method: .head)
    let response = await request.serializingData().response

    if let contentLength = response.response?.expectedContentLength, contentLength > 0 {
      return contentLength
    }

    throw URLError(.cannotDecodeContentData)
  }

  private func downloadChunk(
    url: URL,
    range: ClosedRange<Int64>,
    fileHandle: FileHandle,
    options: DownloadOptions
  ) async throws {

    var attempts = 0
    while attempts <= options.maxRetries {
      do {
        let headers: HTTPHeaders = [
          "Range": "bytes=\(range.lowerBound)-\(range.upperBound)"
        ]

        let request = session.request(url, method: .get, headers: headers)
        let data = try await request.serializingData().value

        // Write data
        // In macOS 10.15+, seekToEnd is a throw function and handling is simpler.
        // We are inside @available block, so standard try works.
        try fileHandle.write(contentsOf: data)

        return  // Success

      } catch {
        attempts += 1
        if attempts > options.maxRetries {
          throw error
        }
        // Wait before retry
        try await Task.sleep(nanoseconds: UInt64(options.retryInterval * 1_000_000_000))
      }
    }
  }
}

// MARK: - Helper

extension URL {
  var queryParameters: [String: String]? {
    guard let components = URLComponents(url: self, resolvingAgainstBaseURL: true),
      let queryItems = components.queryItems
    else { return nil }
    return queryItems.reduce(into: [String: String]()) { (result, item) in
      result[item.name] = item.value
    }
  }
}
