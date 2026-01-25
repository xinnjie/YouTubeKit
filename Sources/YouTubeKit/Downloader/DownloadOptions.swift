import Foundation

/// Configuration options for `StreamDownloader`.
public struct DownloadOptions: Sendable {
    
    /// The size of each download chunk in bytes.
    ///
    /// YouTube throttles connections that download too much data at once.
    /// Using chunked downloads with range requests helps avoid this throttling.
    /// Defaults to 10MB (10 * 1024 * 1024 bytes).
    public var chunkSize: Int
    
    /// The maximum number of retry attempts for a failed chunk.
    /// Defaults to 5.
    public var maxRetries: Int
    
    /// The number of seconds to wait before retrying a failed chunk.
    /// Defaults to 2.0.
    public var retryInterval: TimeInterval
    
    public init(
        chunkSize: Int = 10 * 1024 * 1024,
        maxRetries: Int = 5,
        retryInterval: TimeInterval = 2.0
    ) {
        self.chunkSize = chunkSize
        self.maxRetries = maxRetries
        self.retryInterval = retryInterval
    }
    
    public static let `default` = DownloadOptions()
}

/// Represents the progress of a download.
public struct DownloadProgress: Sendable {
    /// The number of bytes downloaded so far.
    public let bytesDownloaded: Int64
    
    /// The total expected size of the download in bytes.
    public let totalBytes: Int64
    
    /// The fraction of the download that is complete (0.0 to 1.0).
    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(totalBytes)
    }
}
