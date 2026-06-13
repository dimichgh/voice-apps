import Foundation

/// Lightweight stderr logger. Murmur's whole pipeline (hotkey → capture →
/// transcribe → paste) runs against live macOS permissions and a target app,
/// none of which can be unit-tested — so a timestamped trace is the only way to
/// see what happened. Run the built binary from a terminal to watch it:
///   ./Murmur.app/Contents/MacOS/Murmur
enum DebugLog {
    static var enabled = true

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let t = ProcessInfo.processInfo.systemUptime
        FileHandle.standardError.write(Data(String(format: "[murmur %.3f] %@\n", t, message()).utf8))
    }
}
