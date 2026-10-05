import Foundation

/// Small append-only failure log in Documents, visible on the phone under
/// Files > On My iPhone > Tweet > diagnostics.log (Info.plist has UIFileSharingEnabled).
///
/// Why this exists: some failures (a feed page or an edit that silently times out) are
/// rare and happen away from Xcode. `print` is discarded in a Release build with no
/// debugger attached, and os_log text is redacted off-device, so neither can be read
/// later. The console mirror to `app.log` is deliberately off (AppDelegate), so this
/// records only failures — one line each — rather than all console output.
///
/// Thread-safe and non-blocking: callers hand the line to a serial utility queue.
enum DiagnosticLog {
    private static let fileName = "diagnostics.log"
    /// Bounded so an error storm cannot grow the file without limit. When the cap is
    /// reached the file restarts empty; the newest failures are what matter.
    private static let maxBytes = 256 * 1024
    private static let queue = DispatchQueue(label: "app.diagnostic.log", qos: .utility)
    // Only ever touched from `queue` (serial), which is what makes nonisolated(unsafe) sound.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func error(_ category: String, _ message: String) {
        let now = Date()
        queue.async {
            let line = "\(formatter.string(from: now)) [\(category)] \(message)\n"
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                  let data = line.data(using: .utf8) else { return }
            let url = docs.appendingPathComponent(fileName)
            let fm = FileManager.default

            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size >= maxBytes {
                try? fm.removeItem(at: url)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
