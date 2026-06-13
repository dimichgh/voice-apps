import Foundation

/// Lightweight file logger so we can debug the running .app (whose stdout we
/// can't see). Writes to ~/voicechat-debug.log. Remove once stable.
enum DebugLog {
    private static let url = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent("voicechat-debug.log")
    private static let q = DispatchQueue(label: "voicechat.debuglog")

    static func log(_ msg: String) {
        q.async {
            let line = "[\(Date())] \(msg)\n"
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? line.data(using: .utf8)?.write(to: url)
            }
        }
    }
}
