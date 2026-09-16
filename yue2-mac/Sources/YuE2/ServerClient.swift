import Foundation
import AppKit

// MARK: - Wire types (server/server.py)

struct JobResult: Decodable {
    var flac: String?
    var mp3: String?
    var abc: String?
    var audio_seconds: Double?
    var seconds: Double?
    var truncated: Bool?
}

struct JobStatus: Decodable {
    var id: String
    var kind: String
    var state: String          // queued | running | done | error | cancelled
    var phase: String
    var tokens: Int
    var step: Int
    var total_steps: Int
    var elapsed: Double
    var error: String?
    var result: JobResult?

    var isTerminal: Bool { ["done", "error", "cancelled"].contains(state) }
}

struct ServerError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

// MARK: - HTTP client

final class ServerClient {
    static let shared = ServerClient()
    let baseURL = URL(string: "http://127.0.0.1:8810")!

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func health() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 2
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func generate(style: String, lyrics: String, cot: String, steps: Int, seed: Int, abc: String? = nil,
                  instrumental: Bool = false) async throws -> JobStatus {
        var body: [String: Any] = ["style": style, "lyrics": lyrics, "cot": cot, "steps": steps, "seed": seed,
                                   "instrumental": instrumental]
        if let abc { body["abc"] = abc }
        return try await post("generate", body)
    }

    func transcribe(path: String) async throws -> JobStatus {
        try await post("transcribe", ["path": path])
    }

    func job(_ id: String) async throws -> JobStatus {
        let (data, resp) = try await session.data(from: baseURL.appendingPathComponent("jobs/\(id)"))
        try Self.check(resp, data)
        return try JSONDecoder().decode(JobStatus.self, from: data)
    }

    func cancel(_ id: String) async {
        var req = URLRequest(url: baseURL.appendingPathComponent("jobs/\(id)/cancel"))
        req.httpMethod = "POST"
        _ = try? await session.data(for: req)
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> JobStatus {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw ServerError(message: "YuE2 server is not reachable at \(baseURL.absoluteString).")
        }
        try Self.check(resp, data)
        return try JSONDecoder().decode(JobStatus.self, from: data)
    }

    /// FastAPI errors are `{"detail": "..."}` (HTTPException) or `{"detail": [{msg: ...}]}` (validation).
    static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let detail = json?["detail"] as? String {
            throw ServerError(message: detail)
        }
        if let items = json?["detail"] as? [[String: Any]] {
            throw ServerError(message: items.compactMap { $0["msg"] as? String }.joined(separator: "; "))
        }
        throw ServerError(message: "Server error \(http.statusCode)")
    }
}

// MARK: - Launcher

/// Starts server/server.py under ../.venv-yue2 when nothing is listening yet,
/// and stops it on quit only if this app started it.
@MainActor
final class ServerLauncher: ObservableObject {
    enum State { case starting, ready, failed(String) }

    @Published var state: State = .starting
    private var process: Process?
    private var terminateObserver: NSObjectProtocol?

    init() {
        // Registered here rather than on a view so it still fires after the window is closed.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopIfOwned() }
        }
    }

    var statusText: String {
        switch state {
        case .starting: return "Starting YuE2 server…"
        case .ready: return "YuE2 server ready"
        case .failed(let message): return message
        }
    }

    /// yue2-mac/ — the directory holding YuE2.app (or the package dir under `swift run`).
    private var appRoot: URL {
        let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: bundleDir.appendingPathComponent("server/server.py").path) {
            return bundleDir
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Views/llm/yue2-mac")
    }

    func ensureRunning() async {
        state = .starting
        if await ServerClient.shared.health() {
            state = .ready
            return
        }
        // MLX backend (vanch007/mlx-Yue checkout next to yue2-mac, py3.12 venv).
        let python = appRoot.deletingLastPathComponent().appendingPathComponent("mlx-yue/.venv/bin/python")
        let script = appRoot.appendingPathComponent("server/server.py")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            state = .failed("Missing \(python.path)")
            return
        }
        let logURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/YuE2-server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)

        let p = Process()
        p.executableURL = python
        p.arguments = [script.path, "--port", "8810"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.standardOutput = log
        p.standardError = log
        do {
            try p.run()
        } catch {
            state = .failed("Could not start server: \(error.localizedDescription)")
            return
        }
        process = p
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !p.isRunning {
                state = .failed("Server exited — see ~/Library/Logs/YuE2-server.log")
                return
            }
            if await ServerClient.shared.health() {
                state = .ready
                return
            }
        }
        state = .failed("Server did not start — see ~/Library/Logs/YuE2-server.log")
    }

    func stopIfOwned() {
        process?.terminate()
        process = nil
    }
}
