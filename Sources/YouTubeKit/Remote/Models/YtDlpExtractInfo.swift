//
//  YtDlpExtractInfo.swift
//  YouTubeKit
//
//  Created by Cascade on 2026.
//

import Foundation

struct YtDlpExtractInfo: Decodable, Sendable {
  let id: String
  let title: String
  let formats: [Format]

  struct Format: Decodable, Sendable {
    let formatID: String
    let url: String
    let ext: String
    let formatNote: String?
    let format: String?
    let sourcePreference: Int?
    let fps: Double?
    let height: Int?
    let width: Int?
    let tbr: Double?
    let abr: Double?
    let vbr: Double?
    let asr: Int?
    let audioChannels: Int?
    let quality: Double?
    let hasDrm: Bool?
    let vcodec: String?
    let acodec: String?
    let dynamicRange: String?
    let container: String?
    let availableAt: Int?
    let protocolField: String?
    let audioExt: String?
    let videoExt: String?
    let resolution: String?
    let aspectRatio: Double?
    let downloaderOptions: DownloaderOptions?
    let httpHeaders: [String: String]?
    let filesize: Int?
    let filesizeApprox: Int?

    struct DownloaderOptions: Decodable, Sendable {
      let httpChunkSize: Int?

      enum CodingKeys: String, CodingKey {
        case httpChunkSize = "http_chunk_size"
      }
    }

    enum CodingKeys: String, CodingKey {
      case formatID = "format_id"
      case url
      case ext
      case formatNote = "format_note"
      case format
      case sourcePreference = "source_preference"
      case fps
      case height
      case width
      case tbr
      case abr
      case vbr
      case asr
      case audioChannels = "audio_channels"
      case quality
      case hasDrm = "has_drm"
      case vcodec
      case acodec
      case dynamicRange = "dynamic_range"
      case container
      case availableAt = "available_at"
      case protocolField = "protocol"
      case audioExt = "audio_ext"
      case videoExt = "video_ext"
      case resolution
      case aspectRatio = "aspect_ratio"
      case downloaderOptions = "downloader_options"
      case httpHeaders = "http_headers"
      case filesize
      case filesizeApprox = "filesize_approx"
    }
  }
}
