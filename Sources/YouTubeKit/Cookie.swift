import Foundation

#if canImport(YTDLPAPI)
  import YTDLPAPI
#endif

// MARK: - YouTube.Cookie

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
extension YouTube {

  /// Represents an HTTP cookie for YouTube requests
  public struct Cookie: Hashable, Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expiresUnix: Int64
    public let httpOnly: Bool
    public let secure: Bool

    public init(
      name: String,
      value: String,
      domain: String = ".youtube.com",
      path: String = "/",
      expiresUnix: Int64 = 0,
      httpOnly: Bool = false,
      secure: Bool = true
    ) {
      self.name = name
      self.value = value
      self.domain = domain
      self.path = path
      self.expiresUnix = expiresUnix
      self.httpOnly = httpOnly
      self.secure = secure
    }

    #if canImport(YTDLPAPI)
      /// Convert to protobuf Cookie message
      func toProto() -> Ytdlp_V1_Cookie {
        Ytdlp_V1_Cookie.with {
          $0.name = name
          $0.value = value
          $0.domain = domain
          $0.path = path
          $0.expiresUnix = expiresUnix
          $0.httpOnly = httpOnly
          $0.secure = secure
        }
      }

      /// Create from protobuf Cookie message
      static func from(_ proto: Ytdlp_V1_Cookie) -> Cookie {
        Cookie(
          name: proto.name,
          value: proto.value,
          domain: proto.domain,
          path: proto.path,
          expiresUnix: proto.expiresUnix,
          httpOnly: proto.httpOnly,
          secure: proto.secure
        )
      }
    #endif

    // MARK: - HTTPCookie Conversion

    #if canImport(Foundation)
      /// Convert from Foundation HTTPCookie to YouTube.Cookie
      /// - Parameter httpCookie: HTTPCookie object from URLSession or WKWebView
      /// - Returns: YouTube.Cookie with all properties mapped
      public static func from(_ httpCookie: HTTPCookie) -> Cookie {
        Cookie(
          name: httpCookie.name,
          value: httpCookie.value,
          domain: httpCookie.domain,
          path: httpCookie.path,
          expiresUnix: Int64(httpCookie.expiresDate?.timeIntervalSince1970 ?? 0),
          httpOnly: httpCookie.isHTTPOnly,
          secure: httpCookie.isSecure
        )
      }

      /// Batch convert multiple HTTPCookies to YouTube.Cookies
      /// - Parameter httpCookies: Array of HTTPCookie objects
      /// - Returns: Array of YouTube.Cookie objects
      public static func from(_ httpCookies: [HTTPCookie]) -> [Cookie] {
        httpCookies.map { from($0) }
      }
    #endif
  }
}
