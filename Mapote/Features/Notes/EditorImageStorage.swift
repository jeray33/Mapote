import Foundation
import UIKit
import WebKit

/// Stores editor images in a sandboxed directory and serves them to WKWebView
/// via the `mapote-img://` custom URL scheme. Keeps note JSON small (just a
/// short URL string per image) without requiring broad file:// access.
enum EditorImageStorage {
    static let scheme = "mapote-img"

    static var directory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = base.appendingPathComponent("EditorImages", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            var mutable = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutable.setResourceValues(values)
        }
        return dir
    }

    @discardableResult
    static func save(_ data: Data, ext: String = "jpg") -> String? {
        let filename = "\(UUID().uuidString).\(ext.isEmpty ? "jpg" : ext)"
        let url = directory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return "\(scheme)://\(filename)"
        } catch {
            return nil
        }
    }

    /// Maps a `mapote-img://<filename>` URL back to its on-disk location.
    static func fileURL(for schemeURL: URL) -> URL? {
        guard schemeURL.scheme == scheme else { return nil }
        let prefix = "\(scheme)://"
        let s = schemeURL.absoluteString
        guard s.hasPrefix(prefix) else { return nil }
        let filename = String(s.dropFirst(prefix.count))
            .removingPercentEncoding ?? String(s.dropFirst(prefix.count))
        if filename.isEmpty || filename.contains("/") || filename.contains("..") {
            return nil
        }
        return directory.appendingPathComponent(filename)
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic", "heif": return "image/heic"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        default: return "application/octet-stream"
        }
    }
}

/// Bridges `mapote-img://...` requests inside WKWebView to bytes on disk.
final class EditorImageSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let fileURL = EditorImageStorage.fileURL(for: url),
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else {
            urlSchemeTask.didFailWithError(
                NSError(domain: "EditorImageScheme", code: 404)
            )
            return
        }
        let mime = EditorImageStorage.mimeType(forExtension: fileURL.pathExtension)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": "\(data.count)",
                "Cache-Control": "public, max-age=31536000, immutable"
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

struct EditorImageInsertion: Identifiable, Equatable {
    let id = UUID()
    var url: String
}
