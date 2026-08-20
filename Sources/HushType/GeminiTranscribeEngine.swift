import Foundation
import os

private let geminiTranscribeLog = Logger(
    subsystem: "com.felix.hushtype",
    category: "geminiTranscribe"
)

final class GeminiTranscribeEngine: TranscriptionEngine {
    private static let providerMaxSampleCount = 16_000 * 420
    private static let instruction = "Transcribe this audio verbatim. The speech may mix Mandarin and English; transcribe each language exactly as spoken. Use Traditional Chinese (繁體中文) characters for all Mandarin. Output only the transcript."

    private let redirectDelegate: RedirectRefusingDelegate
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false

        let redirectDelegate = RedirectRefusingDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    var isLoaded: Bool { true }
    var maxSampleCount: Int? { Self.providerMaxSampleCount }

    func load(progressHandler: ((Double, String) -> Void)?) async throws {}

    func transcribe(audio: [Float], language: String?) async throws -> String {
        let apiKey: String
        switch GeminiKeyStore.load() {
        case .ok(let key), .unusualFormat(let key):
            apiKey = key
        case .empty:
            throw TranscriptionError.noKey
        }

        guard audio.count <= Self.providerMaxSampleCount else {
            throw TranscriptionError.payloadTooLarge
        }
        guard !audio.isEmpty else { return "" }
        guard !CloudDictationReachability.shared.isKnownOffline else {
            throw TranscriptionError.network
        }

        let model = AppConfig.shared.cloudDictationModelGemini
        guard let endpoint = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        ) else {
            throw TranscriptionError.malformedResponse
        }

        let wavData = WAVEncoder.encode(samples: audio)
        let requestBody: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    [
                        "inlineData": [
                            "mimeType": "audio/wav",
                            "data": wavData.base64EncodedString(),
                        ],
                    ],
                    ["text": Self.instruction],
                ],
            ]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": [
                    "type": "object",
                    "properties": [
                        "transcript": ["type": "string"],
                    ],
                    "required": ["transcript"],
                ],
                "temperature": 0,
                "maxOutputTokens": 8192,
            ],
        ]

        let encodedBody: Data
        do {
            encodedBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw TranscriptionError.malformedResponse
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encodedBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .timedOut {
                throw TranscriptionError.timeout
            }
            throw TranscriptionError.network
        } catch {
            throw TranscriptionError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.network
        }

        guard (200..<300).contains(http.statusCode) else {
            logHTTPFailure(statusCode: http.statusCode, data: data)
            switch http.statusCode {
            case 401, 403:
                throw TranscriptionError.auth
            case 429:
                throw TranscriptionError.rateLimited(provider: "Gemini")
            default:
                throw TranscriptionError.network
            }
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            logHTTPFailure(statusCode: http.statusCode, data: data)
            throw TranscriptionError.malformedResponse
        }

        if let promptFeedback = json["promptFeedback"] as? [String: Any],
           let blockReason = promptFeedback["blockReason"] as? String,
           !blockReason.isEmpty {
            throw TranscriptionError.safetyBlocked
        }

        guard let candidates = json["candidates"] as? [[String: Any]],
              let candidate = candidates.first else {
            logHTTPFailure(statusCode: http.statusCode, data: data)
            throw TranscriptionError.malformedResponse
        }

        let finishReason = candidate["finishReason"] as? String
        if finishReason == "SAFETY" {
            throw TranscriptionError.safetyBlocked
        }
        if finishReason == "MAX_TOKENS" {
            throw TranscriptionError.malformedResponse
        }

        guard let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String,
              let transcriptData = text.data(using: .utf8),
              let transcriptObject = try? JSONSerialization.jsonObject(with: transcriptData),
              let transcriptJSON = transcriptObject as? [String: Any],
              let rawTranscript = transcriptJSON["transcript"] as? String else {
            logHTTPFailure(statusCode: http.statusCode, data: data)
            throw TranscriptionError.malformedResponse
        }

        return DictationPostProcessor.apply(rawTranscript)
    }

    private func logHTTPFailure(statusCode: Int, data: Data) {
        let snippet = String(decoding: data.prefix(512), as: UTF8.self)
        geminiTranscribeLog.error(
            "HTTP \(statusCode, privacy: .public): \(snippet, privacy: .private)"
        )
    }
}
