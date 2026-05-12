import Foundation

enum GeminiServiceError: Error {
    case missingAPIKey
    case invalidResponse
}

actor GeminiService {
    static let shared = GeminiService()

    private let base = "https://generativelanguage.googleapis.com/v1beta/models"
    private var apiKey: String {
        UserDefaults.standard.string(forKey: AppConfigKey.geminiAPIKey)
        ?? ProcessInfo.processInfo.environment["VITE_GEMINI_API_KEY"]
        ?? Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String
        ?? ""
    }

    func extractPlaces(from text: String) async throws -> AIExtractResult {
        guard !apiKey.isEmpty else { throw GeminiServiceError.missingAPIKey }
        let prompt = """
        你是一个地点提取专家。从以下文本中提取所有具体地点，返回JSON：
        {
          "region":"推断城市",
          "places":[{"name":"地点名","searchQuery":"地点名 城市","aliases":[],"kind":"specific_place"}]
        }
        文本：
        \(text)
        """
        let raw = try await generateJSON(prompt: prompt)
        return try JSONDecoder().decode(AIExtractResult.self, from: Data(raw.utf8))
    }

    func suggestDurations(placeNames: [String]) async throws -> [String: String] {
        guard !apiKey.isEmpty else { throw GeminiServiceError.missingAPIKey }
        let joined = placeNames.joined(separator: "、")
        let prompt = """
        对以下地点给出建议游玩时长，返回 JSON 对象，格式为 {"地点名":"1-2小时"}：
        \(joined)
        """
        let raw = try await generateJSON(prompt: prompt)
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return dict
    }

    func chatStream(messages: [ChatMessage], noteContext: [String], onChunk: @escaping @MainActor (String) -> Void) async throws -> String {
        guard !apiKey.isEmpty else { throw GeminiServiceError.missingAPIKey }
        let systemPrompt = """
        你是一个专业的旅行规划助手。请用中文回复，尽量按 Day 分组，并在推荐地点时输出 ```json:places``` 代码块。
        用户当前笔记中已有以下地点：\(noteContext.joined(separator: "、"))，请避免重复推荐。
        """

        let contents: [[String: Any]] = ([ChatMessage(role: .user, content: systemPrompt)] + messages).map { msg in
            [
                "role": msg.role == .assistant ? "model" : "user",
                "parts": [["text": msg.content]]
            ]
        }
        let urlString = "\(base)/gemini-2.0-flash:streamGenerateContent?alt=sse&key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw GeminiServiceError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "contents": contents,
            "generationConfig": ["temperature": 0.8, "maxOutputTokens": 4096]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GeminiServiceError.invalidResponse }
        var full = ""
        for try await line in bytes.lines where line.hasPrefix("data: ") {
            let raw = String(line.dropFirst(6))
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = obj["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String
            else { continue }
            full += text
            await onChunk(full)
        }
        return full
    }

    private func generateJSON(prompt: String) async throws -> String {
        guard !apiKey.isEmpty else { throw GeminiServiceError.missingAPIKey }
        let urlString = "\(base)/gemini-2.0-flash:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw GeminiServiceError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "response_mime_type": "application/json",
                "temperature": 0
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GeminiServiceError.invalidResponse }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String
        else {
            throw GeminiServiceError.invalidResponse
        }
        return text
    }
}

