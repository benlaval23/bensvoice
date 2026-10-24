import Foundation

/// Turns a spoken instruction into finished text using Claude Haiku.
/// Uses an API key from config.json if present (fastest), otherwise the logged-in `claude` CLI (your subscription).
enum Composer {
    static let systemPrompt = """
    You are a writing assistant that drafts text the user will insert directly into whatever app they are typing in.
    The user speaks an instruction such as "reply saying I can do Thursday but not Friday" or "write a short description of X, Y and Z".
    Rules:
    - Output ONLY the final text to insert. No preamble, no quotes, no explanations, no markdown headings.
    - Write in first person as the user. Match the register of the app: casual and brief for chat apps (Slack, Messages, WhatsApp, Discord), \
    clear and professional for email, precise and technical for coding tools and AI assistants (Terminal, Claude, ChatGPT, editors).
    - If selected text is provided, treat it as context: the message being replied to, or the text to rewrite if the user asks for a rewrite.
    - If the user is dictating the message itself rather than giving an instruction, just clean it up.
    - Keep it as short as the request allows. Never invent facts the user did not give.
    """

    struct Config: Decodable {
        var anthropicApiKey: String?
        var model: String?
        var cliModel: String?
        var modelDir: String?
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BensVoice/config.json")
    }

    static func loadConfig() -> Config {
        guard let data = try? Data(contentsOf: configURL),
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return c
    }

    static func compose(instruction: String, selectedText: String?, appName: String?) throws -> String {
        var prompt = "App: \(appName ?? "unknown")\n"
        if let sel = selectedText, !sel.isEmpty { prompt += "Selected text:\n<<<\n\(sel)\n>>>\n" }
        prompt += "Instruction: \(instruction)"

        let config = loadConfig()
        let result: String
        if let key = config.anthropicApiKey ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            result = try viaAPI(prompt: prompt, key: key, model: config.model ?? "claude-haiku-5-5")
        } else {
            result = try viaCLI(prompt: prompt, model: config.cliModel ?? "haiku")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func viaAPI(prompt: String, key: String, model: String) throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [["role": "user", "content": prompt]],
        ])
        var output: Result<String, Error> = .failure(fail("No response"))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, err in
            defer { done.signal() }
            if let err { output = .failure(err); return }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                output = .failure(fail("Bad response")); return
            }
            if let content = json["content"] as? [[String: Any]] {
                output = .success(content.compactMap { $0["text"] as? String }.joined())
            } else {
                let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "API error"
                output = .failure(fail(msg))
            }
        }.resume()
        done.wait()
        return try output.get()
    }

    private static func viaCLI(prompt: String, model: String) throws -> String {
        guard let claude = findClaude() else { throw fail("Couldn't find the `claude` CLI") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = ["-p", "--model", model, "--system-prompt", systemPrompt,
                       "--tools", "", "--no-session-persistence", "--strict-mcp-config",
                       "--setting-sources", "", "--disable-slash-commands"]
        let workDir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        p.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(URL(fileURLWithPath: claude).deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        try p.run()
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: out, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw fail(String(decoding: err.isEmpty ? out : err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }

    private static func findClaude() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func fail(_ msg: String) -> NSError {
        NSError(domain: "BensVoice", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
