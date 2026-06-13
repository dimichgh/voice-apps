import Foundation

protocol ToolHandler {
    var name: String { get }
    var description: String { get }
    var schema: JSONSchema { get }
    func run(args: [String: Any]) async throws -> String
}

final class ToolRegistry {
    private var handlers: [String: ToolHandler] = [:]

    var openAITools: [Tool] {
        handlers.values.map { h in
            Tool(type: "function",
                 function: ToolFunction(name: h.name, description: h.description, parameters: h.schema))
        }
    }

    func register(_ h: ToolHandler) { handlers[h.name] = h }

    func run(call: ToolCall) async -> String {
        guard let h = handlers[call.function.name] else {
            return "ERROR: unknown tool '\(call.function.name)'"
        }
        let argsData = call.function.arguments.data(using: .utf8) ?? Data()
        let args = (try? JSONSerialization.jsonObject(with: argsData)) as? [String: Any] ?? [:]
        do {
            return try await h.run(args: args)
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }
}

// ---------------- Built-in tools ----------------

struct GetCurrentTimeTool: ToolHandler {
    let name = "get_current_time"
    let description = "Returns the current local date and time in ISO-8601 form."
    let schema = JSONSchema(type: "object", properties: [:], required: [])
    func run(args: [String: Any]) async throws -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: Date())
    }
}

struct ListDirectoryTool: ToolHandler {
    let name = "list_directory"
    let description = "Lists the entries in a directory on the user's machine."
    let schema = JSONSchema(
        type: "object",
        properties: [
            "path": JSONSchemaProperty(
                type: "string",
                description: "Absolute path of the directory to list.",
                enumValues: nil)
        ],
        required: ["path"])
    func run(args: [String: Any]) async throws -> String {
        guard let path = args["path"] as? String else { return "ERROR: missing 'path'" }
        let expanded = (path as NSString).expandingTildeInPath
        let items = try FileManager.default.contentsOfDirectory(atPath: expanded)
        if items.isEmpty { return "(empty directory)" }
        return items.sorted().joined(separator: "\n")
    }
}

struct RunShellTool: ToolHandler {
    let name = "run_shell"
    let description = "Runs a shell command via /bin/sh -c and returns combined stdout+stderr. Use sparingly."
    let schema = JSONSchema(
        type: "object",
        properties: [
            "command": JSONSchemaProperty(
                type: "string",
                description: "Command line to execute.",
                enumValues: nil)
        ],
        required: ["command"])
    func run(args: [String: Any]) async throws -> String {
        guard let cmd = args["command"] as? String else { return "ERROR: missing 'command'" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.isEmpty ? "(no output; exit code \(p.terminationStatus))" : out
    }
}

struct ReadFileTool: ToolHandler {
    let name = "read_file"
    let description = "Reads a UTF-8 text file from the user's machine. Truncates after 8 KB."
    let schema = JSONSchema(
        type: "object",
        properties: [
            "path": JSONSchemaProperty(
                type: "string",
                description: "Absolute path of the file to read.",
                enumValues: nil)
        ],
        required: ["path"])
    func run(args: [String: Any]) async throws -> String {
        guard let path = args["path"] as? String else { return "ERROR: missing 'path'" }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        let trimmed = data.prefix(8 * 1024)
        return String(data: trimmed, encoding: .utf8)
            ?? "ERROR: file is not valid UTF-8 text"
    }
}

struct WriteFileTool: ToolHandler {
    let name = "write_file"
    let description = "Creates or overwrites a UTF-8 text file on the user's machine. Parent directories must already exist."
    let schema = JSONSchema(
        type: "object",
        properties: [
            "path": JSONSchemaProperty(
                type: "string",
                description: "Absolute path of the file to write. ~ is expanded.",
                enumValues: nil),
            "content": JSONSchemaProperty(
                type: "string",
                description: "Full UTF-8 contents to write to the file.",
                enumValues: nil),
        ],
        required: ["path", "content"])
    func run(args: [String: Any]) async throws -> String {
        guard let path = args["path"] as? String else { return "ERROR: missing 'path'" }
        guard let content = args["content"] as? String else { return "ERROR: missing 'content'" }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        try content.data(using: .utf8)?.write(to: url, options: [.atomic])
        return "Wrote \(content.utf8.count) bytes to \(expanded)"
    }
}

/// Searches the public web. Uses Tavily (best quality) when `TAVILY_API_KEY`
/// is set in the environment, otherwise falls back to DuckDuckGo's Instant
/// Answer API (works well for entity-style queries, sparse for general).
struct WebSearchTool: ToolHandler {
    let name = "web_search"
    let description = "Search the public web. Returns top result titles, URLs, and snippets. Use for current events, factual lookups, and finding pages by topic."
    let schema = JSONSchema(
        type: "object",
        properties: [
            "query": JSONSchemaProperty(
                type: "string",
                description: "Natural-language search query.",
                enumValues: nil),
            "max_results": JSONSchemaProperty(
                type: "integer",
                description: "How many results to return (1-10). Defaults to 5.",
                enumValues: nil),
        ],
        required: ["query"])

    func run(args: [String: Any]) async throws -> String {
        guard let query = (args["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else { return "ERROR: missing 'query'" }
        let n = max(1, min(10, (args["max_results"] as? Int) ?? 5))

        if let key = ProcessInfo.processInfo.environment["TAVILY_API_KEY"], !key.isEmpty {
            return try await tavilySearch(query: query, maxResults: n, apiKey: key)
        }
        return try await ddgInstantAnswer(query: query)
    }

    private func tavilySearch(query: String, maxResults: Int, apiKey: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": maxResults,
            "include_answer": true,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "ERROR: tavily returned non-JSON"
        }
        var out: [String] = []
        if let answer = obj["answer"] as? String, !answer.isEmpty {
            out.append("Direct answer: \(answer)\n")
        }
        if let results = obj["results"] as? [[String: Any]] {
            for (i, r) in results.prefix(maxResults).enumerated() {
                let title = r["title"] as? String ?? "(no title)"
                let url = r["url"] as? String ?? ""
                let snippet = (r["content"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                out.append("[\(i + 1)] \(title)\n    \(url)\n    \(snippet)")
            }
        }
        return out.isEmpty ? "No results." : out.joined(separator: "\n\n")
    }

    private func ddgInstantAnswer(query: String) async throws -> String {
        var comps = URLComponents(string: "https://api.duckduckgo.com/")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "ERROR: ddg returned non-JSON"
        }
        var lines: [String] = []
        if let heading = obj["Heading"] as? String, !heading.isEmpty {
            lines.append("Heading: \(heading)")
        }
        if let abstract = obj["AbstractText"] as? String, !abstract.isEmpty {
            lines.append("Abstract: \(abstract)")
        }
        if let url = obj["AbstractURL"] as? String, !url.isEmpty {
            lines.append("URL: \(url)")
        }
        if let answer = obj["Answer"] as? String, !answer.isEmpty {
            lines.append("Answer: \(answer)")
        }
        if let related = obj["RelatedTopics"] as? [[String: Any]], !related.isEmpty {
            lines.append("\nRelated:")
            for r in related.prefix(5) {
                if let text = r["Text"] as? String, !text.isEmpty {
                    let url = r["FirstURL"] as? String ?? ""
                    lines.append("- \(text) \(url.isEmpty ? "" : "(\(url))")")
                }
            }
        }
        if lines.isEmpty {
            return "DuckDuckGo had no instant answer for \"\(query)\". Set TAVILY_API_KEY in the environment for richer general-web results."
        }
        return lines.joined(separator: "\n")
    }
}
