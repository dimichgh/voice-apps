import Foundation

/// Lightweight logger. Murmur's whole pipeline (hotkey → capture → transcribe →
/// paste) runs against live macOS permissions and a target app, none of which
/// can be unit-tested — so a timestamped trace is the only way to see what
/// happened. Writes to stderr AND appends to ~/murmur-solo.log, so the trace is
/// capturable even when the app is launched from Finder (no terminal attached):
///   tail -f ~/murmur-solo.log
enum DebugLog {
    static var enabled = true

    /// ~/<AppName>.log — readable regardless of how the app was launched.
    private static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("\(ProcessInfo.processInfo.processName).log")

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let t = ProcessInfo.processInfo.systemUptime
        let data = Data(String(format: "[murmur %.3f] %@\n", t, message()).utf8)
        FileHandle.standardError.write(data)
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        }
    }
}
