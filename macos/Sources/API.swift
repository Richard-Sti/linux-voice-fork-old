import Foundation

struct HTTPError: LocalizedError {
    let status: Int
    let body: String
    var errorDescription: String? { "HTTP \(status): \(body.prefix(300))" }
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func send(_ request: URLRequest, body: Data) async throws -> Data {
    let (data, response) = try await URLSession.shared.upload(for: request, from: body)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw HTTPError(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
    }
    return data
}

private func json(_ data: Data) throws -> [String: Any] {
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw APIError(message: "Unexpected response: \(String(decoding: data, as: UTF8.self).prefix(300))")
    }
    return obj
}

/// Phrases Whisper produces from music, noise or silence (it was trained on
/// subtitled video). A transcript consisting only of one is dropped.
private let whisperStockPhrases: Set<String> = [
    "you", "thank you", "thanks", "thank you very much", "thank you so much",
    "thanks for watching", "thank you for watching", "thank you so much for watching",
    "please subscribe", "bye", "subtitles by the amaraorg community",
]

func isLikelyHallucination(_ transcript: String) -> Bool {
    let normalised = transcript.lowercased()
        .filter { $0.isLetter || $0 == " " }
        .split(separator: " ").joined(separator: " ")
    return normalised.isEmpty || whisperStockPhrases.contains(normalised)
}

/// Whisper transcription through an OpenAI-compatible endpoint (Groq or OpenAI).
struct Transcriber {
    let baseURL: URL
    let apiKey: String
    let model: String
    let language: String
    let prompt: String

    func transcribe(wav: Data) async throws -> String {
        let boundary = "voicebar-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
                .data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "text")
        field("temperature", "0")
        if !language.isEmpty { field("language", language) }
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"
            + "Content-Type: audio/wav\r\n\r\n").data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let data = try await send(request, body: body)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Applies a spoken correction to the last dictated text with an LLM.
struct Editor {
    enum Backend {
        /// Claude through the Messages API (raw HTTP: there is no official Swift SDK).
        case anthropic(apiKey: String, model: String, effort: String)
        /// Chat completions on the transcription provider (Groq or OpenAI).
        case chat(baseURL: URL, apiKey: String, model: String)
    }

    let backend: Backend
    let domainContext: String

    static let systemPrompt = """
        You edit text produced by voice dictation. Apply the user's correction instruction to the \
        text and output only the corrected text, with no preamble, quotes or explanation.

        - Apply the instruction to the whole text, not only to its first occurrence.
        - Interpret the instruction generously (for example, "remove filler words" removes all of \
        them), but change nothing the instruction does not ask for.
        - The user writes astrophysics papers in LaTeX, Python code and shell commands. Speech \
        recognition often mishears technical terms; correct them when the instruction asks.
        - When the instruction asks for LaTeX (a citation, maths, a command), write valid LaTeX.
        """

    var label: String {
        switch backend {
        case .anthropic(_, let model, _): return model
        case .chat(_, _, let model): return model
        }
    }

    func correct(_ original: String, instruction: String) async throws -> String {
        var user = "Original text: \(original)\n\nInstruction: \(instruction)"
        if !domainContext.isEmpty { user += "\n\nDomain context: \(domainContext)" }

        switch backend {
        case let .anthropic(apiKey, model, effort):
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 4096,
                "system": Editor.systemPrompt,
                "output_config": ["effort": effort],
                "fallbacks": "default",
                "messages": [["role": "user", "content": user]],
            ]
            let reply = try json(try await send(request, body: JSONSerialization.data(withJSONObject: body)))
            if reply["stop_reason"] as? String == "refusal" {
                throw APIError(message: "Claude declined the edit")
            }
            let blocks = reply["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)

        case let .chat(baseURL, apiKey, model):
            var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "model": model,
                "temperature": 0,
                "messages": [
                    ["role": "system", "content": Editor.systemPrompt],
                    ["role": "user", "content": user],
                ],
            ]
            let reply = try json(try await send(request, body: JSONSerialization.data(withJSONObject: body)))
            let choices = reply["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            guard let text = message?["content"] as? String else {
                throw APIError(message: "No text in chat response")
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
